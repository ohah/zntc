#!/usr/bin/env bun
/**
 * Bundle performance CI comparison runner.
 *
 * 결정론적 fixture 를 같은 CI 머신에서 ZNTC / Rolldown / Rspack 으로 번들링해
 * wall time 을 비교한다. 체크인된 절대 baseline 은 사용하지 않는다.
 *
 * 실행:
 *   bun run tests/benchmark/bundle-perf.ts
 *   bun run tests/benchmark/bundle-perf.ts --output <path>
 *   bun run tests/benchmark/bundle-perf.ts --no-fail
 *
 * 측정 방법론:
 *   - 워밍업 5회 (mtime/dentry 캐시 워밍)
 *   - wall time 측정 20회
 *   - 비교값은 no-profile CLI wall time median
 *   - ZNTC `--profile=all --profile-level=detailed` 는 별도 진단 샘플로만 실행
 */

import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { performance } from 'node:perf_hooks';
import {
  ROOT,
  ZNTC_BIN,
  buildBin as buildBinShared,
  findNodeModulesBin,
  getCommit,
  parseProfileJson,
} from './_runner';
import { computeMetricStats, formatMetric, type JsonStats, toJsonStats } from './stats';

const WARMUP = 5;
const ITERATIONS = 20;
const PROFILE_ITERATIONS = 5;

type ToolName = 'zntc' | 'rolldown' | 'rspack';

const TOOL_ORDER: ToolName[] = ['zntc', 'rolldown', 'rspack'];

function toolLabel(tool: ToolName): string {
  switch (tool) {
    case 'zntc':
      return 'ZNTC';
    case 'rolldown':
      return 'Rolldown';
    case 'rspack':
      return 'Rspack';
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
    Array.from({ length: moduleCount }, (_, i) => `v${i}`).join(', '),
    Array.from({ length: externals.length }, (_, i) => `x${i}`).join(', '),
  ]
    .filter(Boolean)
    .join(', ');
  lines.push(`console.log(${usages});`);
  writeFileSync(join(dir, 'entry.ts'), lines.join('\n'));
  for (let i = 0; i < moduleCount; i++) {
    writeFileSync(join(dir, `mod${i}.ts`), `export const v${i} = ${i};`);
  }
  return join(dir, 'entry.ts');
}

// ─── 측정 ───

interface RunResult {
  wall_ms: number;
  zntc_profile_total_ms?: number;
  phases?: Record<string, number>;
  phase_selfs?: Record<string, number>;
}

function runZntc(
  entry: string,
  outDir: string,
  externals: string[],
  withProfile = false,
): RunResult {
  rmSync(outDir, { recursive: true, force: true });
  mkdirSync(outDir, { recursive: true });
  const args = [
    '--bundle',
    '--format=esm',
    '--splitting',
    ...externals.map((e) => `--external=${e}`),
    entry,
    '--outdir',
    outDir,
  ];
  if (withProfile) {
    args.push('--profile=all', '--profile-level=detailed', '--profile-format=json');
  }

  const start = performance.now();
  const r = spawnSync(ZNTC_BIN, args, { stdio: 'pipe', timeout: 30000 });
  const wall_ms = performance.now() - start;
  if (r.status !== 0) {
    throw new Error(`zntc failed: ${r.stderr?.toString().slice(0, 400)}`);
  }
  if (!withProfile) return { wall_ms };

  const stdout = r.stdout.toString() + '\n' + r.stderr.toString();
  const profile = parseProfileJson(stdout);
  const phases: Record<string, number> = {};
  const phase_selfs: Record<string, number> = {};
  for (const [phase, data] of Object.entries(profile.phases)) {
    if (data) phases[phase] = data.total_ms;
    if (data?.self_ms !== undefined) phase_selfs[phase] = data.self_ms;
  }
  return { wall_ms, zntc_profile_total_ms: profile.total_ms, phases, phase_selfs };
}

function runRolldown(bin: string, entry: string, outDir: string, externals: string[]): RunResult {
  rmSync(outDir, { recursive: true, force: true });
  mkdirSync(outDir, { recursive: true });
  const args = [entry, '--format=esm', '--dir', outDir];
  if (externals.length > 0) args.push('--external', externals.join(','));

  const start = performance.now();
  const r = spawnSync(bin, args, { stdio: 'pipe', timeout: 30000 });
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
  const r = spawnSync(bin, ['build', '--config', configPath], {
    cwd: ROOT,
    stdio: 'pipe',
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
  { name: 'small (10 modules, 0 ext)', module_count: 10, externals: [] },
  { name: 'medium (100 modules, 3 ext)', module_count: 100, externals: ['react', 'vue', 'lodash'] },
  {
    name: 'large (200 modules, 5 ext)',
    module_count: 200,
    externals: ['react', 'vue', 'lodash', 'rxjs', 'zod'],
  },
  {
    name: 'xlarge (1000 modules, 8 ext)',
    module_count: 1000,
    externals: ['react', 'vue', 'lodash', 'rxjs', 'zod', 'axios', 'date-fns', 'three'],
  },
];

interface ToolResult {
  tool: ToolName;
  wall_ms_stats: JsonStats | null;
  zntc_profile_total_ms_stats?: JsonStats;
  phase_median_ms?: Record<string, number>;
  phase_self_median_ms?: Record<string, number>;
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
  zntc_commit: string;
  warmup: number;
  iterations: number;
  profile_iterations: number;
  fixtures: FixtureResult[];
}

// ─── 메인 ───

function buildBin() {
  buildBinShared('bundle-perf');
}

function createRunners(
  entry: string,
  tmp: string,
  externals: string[],
): Partial<Record<ToolName, () => RunResult>> {
  const rolldownBin = findNodeModulesBin('rolldown');
  const rspackBin = findNodeModulesBin('rspack');
  const rspackOut = join(tmp, 'rspack-out');
  const rspackConfig = join(tmp, 'rspack.config.cjs');
  writeRspackConfig(rspackConfig, entry, rspackOut, externals);

  return {
    zntc: () => runZntc(entry, join(tmp, 'zntc-out'), externals),
    rolldown: rolldownBin
      ? () => runRolldown(rolldownBin, entry, join(tmp, 'rolldown-out'), externals)
      : undefined,
    rspack: rspackBin ? () => runRspack(rspackBin, rspackConfig, rspackOut) : undefined,
  };
}

async function measureFixture(spec: FixtureSpec): Promise<FixtureResult> {
  const tmp = mkdtempSync(join(tmpdir(), 'zntc-bundle-perf-'));
  const fixDir = join(tmp, 'src');
  const entry = makeFixture(fixDir, spec.module_count, spec.externals);
  const runners = createRunners(entry, tmp, spec.externals);

  try {
    for (let i = 0; i < WARMUP; i++) {
      for (const tool of TOOL_ORDER) runners[tool]?.();
    }

    const wallSamples: Partial<Record<ToolName, number[]>> = {};
    const zntcProfileTotals: number[] = [];
    const phaseSeries: Record<string, number[]> = {};
    const phaseSelfSeries: Record<string, number[]> = {};

    for (let i = 0; i < ITERATIONS; i++) {
      for (const tool of TOOL_ORDER) {
        const run = runners[tool];
        if (!run) continue;
        const r = run();
        (wallSamples[tool] ??= []).push(r.wall_ms);
      }
    }

    runZntc(entry, join(tmp, 'zntc-profile-warmup'), spec.externals, true);
    for (let i = 0; i < PROFILE_ITERATIONS; i++) {
      const r = runZntc(entry, join(tmp, `zntc-profile-${i}`), spec.externals, true);
      if (r.zntc_profile_total_ms !== undefined) zntcProfileTotals.push(r.zntc_profile_total_ms);
      for (const [k, v] of Object.entries(r.phases ?? {})) {
        (phaseSeries[k] ??= []).push(v);
      }
      for (const [k, v] of Object.entries(r.phase_selfs ?? {})) {
        (phaseSelfSeries[k] ??= []).push(v);
      }
    }

    const phase_median_ms: Record<string, number> = {};
    for (const [k, arr] of Object.entries(phaseSeries)) {
      phase_median_ms[k] = computeStats(arr).median;
    }
    const phase_self_median_ms: Record<string, number> = {};
    for (const [k, arr] of Object.entries(phaseSelfSeries)) {
      phase_self_median_ms[k] = computeStats(arr).median;
    }

    const tools: ToolResult[] = TOOL_ORDER.map((tool) => {
      const samples = wallSamples[tool];
      if (!samples || samples.length === 0) {
        return {
          tool,
          wall_ms_stats: null,
          skipped: tool === 'zntc' ? 'missing zntc runner' : `${tool} binary not found`,
        };
      }
      const result: ToolResult = {
        tool,
        wall_ms_stats: computeStats(samples),
      };
      if (tool === 'zntc') {
        if (zntcProfileTotals.length > 0) {
          result.zntc_profile_total_ms_stats = computeStats(zntcProfileTotals);
          result.phase_median_ms = phase_median_ms;
          result.phase_self_median_ms = phase_self_median_ms;
        }
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
  if (n === null || n === undefined || Number.isNaN(n)) return '-';
  return formatMetric(n, 'ms');
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
    return '-';
  }
  return `${(numerator / denominator).toFixed(2)}x`;
}

function toolResult(fixture: FixtureResult, tool: ToolName): ToolResult | undefined {
  return fixture.tools.find((r) => r.tool === tool);
}

function medianWall(fixture: FixtureResult, tool: ToolName): number | null {
  return toolResult(fixture, tool)?.wall_ms_stats?.median ?? null;
}

function zntcProfileMedian(fixture: FixtureResult): number | null {
  return toolResult(fixture, 'zntc')?.zntc_profile_total_ms_stats?.median ?? null;
}

function fastestTool(fixture: FixtureResult): string {
  const candidates = fixture.tools
    .filter((r): r is ToolResult & { wall_ms_stats: JsonStats } => r.wall_ms_stats !== null)
    .sort((a, b) => a.wall_ms_stats.median - b.wall_ms_stats.median);
  if (candidates.length === 0) return '-';
  const fastest = candidates[0];
  return `${toolLabel(fastest.tool)} (${fmtMarkdownMs(fastest.wall_ms_stats.median)})`;
}

function printReport(runReport: RunReport): void {
  console.log();
  console.log('### bundle-perf — CI tool comparison context');
  console.log('| Field | Value |');
  console.log('| --- | --- |');
  console.log(`| Current run commit | ${runReport.zntc_commit} |`);
  console.log('| Baseline | none; same-run CI wall-time comparison |');
  console.log('| Tools | ZNTC / Rolldown / Rspack |');
  console.log('| Primary metric | CLI wall time median |');
  console.log(
    '| ZNTC profile total | separate --profile=all --profile-level=detailed diagnostic run; not part of wall median |',
  );
  console.log(
    '| ZNTC phase medians | inclusive total_ms; nested child rows overlap, self_ms medians are stored in JSON |',
  );
  console.log(`| Warmup / iterations | ${runReport.warmup} / ${runReport.iterations} |`);
  console.log(`| ZNTC profile iterations | ${runReport.profile_iterations} |`);
  console.log();
  console.log('### bundle-perf — CI wall-time tool comparison');
  console.log(
    '| Fixture | ZNTC wall median | Rolldown wall median | Rspack wall median | Fastest | Rolldown / ZNTC | Rspack / ZNTC | ZNTC profile total |',
  );
  console.log(
    '|---------|-----------------|----------------------|--------------------|---------|----------------|--------------|-------------------|',
  );
  for (const fixture of runReport.fixtures) {
    const zntc = medianWall(fixture, 'zntc');
    const rolldown = medianWall(fixture, 'rolldown');
    const rspack = medianWall(fixture, 'rspack');
    console.log(
      `| ${fixture.name} | ${fmtMarkdownMs(zntc)} | ${fmtMarkdownMs(rolldown)} | ${fmtMarkdownMs(rspack)} | ${fastestTool(fixture)} | ${fmtRatio(rolldown, zntc)} | ${fmtRatio(rspack, zntc)} | ${fmtMarkdownMs(zntcProfileMedian(fixture))} |`,
    );
  }
  console.log();
  console.log('### bundle-perf — ZNTC phase medians (inclusive)');
  console.log('| Fixture | Resolve | Graph | Link | Shake | Transform | Codegen | Emit |');
  console.log('|---------|---------|-------|------|-------|-----------|---------|------|');
  for (const fixture of runReport.fixtures) {
    const phases = toolResult(fixture, 'zntc')?.phase_median_ms ?? {};
    console.log(
      `| ${fixture.name} | ${fmtMarkdownMs(phases.resolve)} | ${fmtMarkdownMs(phases.graph)} | ${fmtMarkdownMs(phases.link)} | ${fmtMarkdownMs(phases.shake)} | ${fmtMarkdownMs(phases.transform)} | ${fmtMarkdownMs(phases.codegen)} | ${fmtMarkdownMs(phases.emit)} |`,
    );
  }
  console.log();
  console.log('### bundle-perf — ZNTC graph discovery read subphase medians (inclusive)');
  console.log(
    '| Fixture | Worker parse | PM setup | Setup read | Read file | Read+stat | Open | Stat | Read bytes | Parser setup |',
  );
  console.log(
    '|---------|--------------|----------|------------|-----------|-----------|------|------|------------|--------------|',
  );
  for (const fixture of runReport.fixtures) {
    const phases = toolResult(fixture, 'zntc')?.phase_median_ms ?? {};
    console.log(
      `| ${fixture.name} | ${fmtMarkdownMs(phases['graph.discover.scan.worker.parse'])} | ${fmtMarkdownMs(phases['graph.discover.pm.setup'])} | ${fmtMarkdownMs(phases['graph.discover.pm.setup.read'])} | ${fmtMarkdownMs(phases['graph.discover.pm.setup.read.file'])} | ${fmtMarkdownMs(phases['graph.discover.pm.setup.read.with.stat'])} | ${fmtMarkdownMs(phases['graph.discover.pm.setup.read.open'])} | ${fmtMarkdownMs(phases['graph.discover.pm.setup.read.stat'])} | ${fmtMarkdownMs(phases['graph.discover.pm.setup.read.bytes'])} | ${fmtMarkdownMs(phases['graph.discover.pm.setup.parser'])} |`,
    );
  }
  console.log();
  console.log('### bundle-perf — ZNTC graph prepass decision subphase medians (inclusive)');
  console.log(
    '| Fixture | Prepass | Decision | Module gate | AST flags | Options | Unsupported walk | Run |',
  );
  console.log(
    '|---------|---------|----------|-------------|-----------|---------|------------------|-----|',
  );
  for (const fixture of runReport.fixtures) {
    const phases = toolResult(fixture, 'zntc')?.phase_median_ms ?? {};
    console.log(
      `| ${fixture.name} | ${fmtMarkdownMs(phases['graph.discover.pm.prepass'])} | ${fmtMarkdownMs(phases['graph.discover.pm.prepass.decision'])} | ${fmtMarkdownMs(phases['graph.discover.pm.prepass.decision.module.gate'])} | ${fmtMarkdownMs(phases['graph.discover.pm.prepass.decision.ast.flags'])} | ${fmtMarkdownMs(phases['graph.discover.pm.prepass.decision.options'])} | ${fmtMarkdownMs(phases['graph.discover.pm.prepass.decision.unsupported.walk'])} | ${fmtMarkdownMs(phases['graph.discover.pm.prepass.run'])} |`,
    );
  }
  console.log();
  console.log('### bundle-perf — ZNTC resolve subphase medians (inclusive)');
  console.log(
    '| Fixture | External | Cache key | Cache lookup | Browser override | Resolver | Path | File exists | Extensions | TS map | Directory index | Realpath | Cache store |',
  );
  console.log(
    '|---------|----------|-----------|--------------|------------------|----------|------|-------------|------------|--------|-----------------|----------|-------------|',
  );
  for (const fixture of runReport.fixtures) {
    const phases = toolResult(fixture, 'zntc')?.phase_median_ms ?? {};
    console.log(
      `| ${fixture.name} | ${fmtMarkdownMs(phases['resolve.external'])} | ${fmtMarkdownMs(phases['resolve.cache.key'])} | ${fmtMarkdownMs(phases['resolve.cache.lookup'])} | ${fmtMarkdownMs(phases['resolve.browser.override'])} | ${fmtMarkdownMs(phases['resolve.resolver'])} | ${fmtMarkdownMs(phases['resolve.path'])} | ${fmtMarkdownMs(phases['resolve.file.exists'])} | ${fmtMarkdownMs(phases['resolve.extensions'])} | ${fmtMarkdownMs(phases['resolve.ts.extension.map'])} | ${fmtMarkdownMs(phases['resolve.directory.index'])} | ${fmtMarkdownMs(phases['resolve.realpath'])} | ${fmtMarkdownMs(phases['resolve.cache.store'])} |`,
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
    if (a === '--no-fail') args.noFail = true;
    else if (a === '--output') args.output = argv[++i] ?? null;
  }
  return args;
}

async function main(cli: CliArgs) {
  buildBin();
  const available = TOOL_ORDER.filter((tool) => tool === 'zntc' || findNodeModulesBin(tool)).join(
    ',',
  );
  console.log(`[bundle-perf] zntc ${getCommit()} | warmup=${WARMUP} iter=${ITERATIONS}`);
  console.log(`[bundle-perf] available tools: ${available}`);
  console.log();

  const fixtures: FixtureResult[] = [];
  for (const spec of FIXTURES) {
    process.stdout.write(`  ${spec.name}... `);
    const r = await measureFixture(spec);
    const zntc = medianWall(r, 'zntc');
    const rolldown = medianWall(r, 'rolldown');
    const rspack = medianWall(r, 'rspack');
    console.log(
      `zntc=${fmtMarkdownMs(zntc)} rolldown=${fmtMarkdownMs(rolldown)} rspack=${fmtMarkdownMs(rspack)} zntc_profile_total=${fmtMarkdownMs(zntcProfileMedian(r))}`,
    );
    fixtures.push(r);
  }

  const runReport: RunReport = {
    version: 3,
    generated_at: new Date().toISOString(),
    zntc_commit: getCommit(),
    warmup: WARMUP,
    iterations: ITERATIONS,
    profile_iterations: PROFILE_ITERATIONS,
    fixtures,
  };

  if (cli.output) {
    writeFileSync(cli.output, JSON.stringify(runReport, null, 2) + '\n');
    console.log(`\n[bundle-perf] run report written: ${cli.output}`);
  }

  printReport(runReport);
}

await main(parseArgs(process.argv.slice(2)));
