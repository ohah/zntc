#!/usr/bin/env bun
/**
 * Mangler property harness — Issue #1760 baseline runner.
 *
 * 각 fixture 에 대해 `zts --bundle --minify --mangle-report=<path>` 를 돌려
 * ManglerReport JSON 을 수집하고 baseline 과 비교한다.
 *
 * Unified mangler 마이그레이션(#1760) 전/후의 property 동치성 검증용.
 * 개별 이름은 Phase A→B counter 공유로 달라질 수 있으므로 집계값으로만 비교:
 *   - bundle_size_bytes: ±1%
 *   - totals.slot_name_length_sum: ±1%
 *   - top_level_reserved_pool: ±2 개 (exact diff 는 의미 없음)
 *
 * 실행:
 *   bun run tests/benchmark/mangler-property.ts          # baseline 과 비교
 *   bun run tests/benchmark/mangler-property.ts --write  # baseline 갱신
 */

import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { COMMON_FIXTURES, type CommonFixture } from "./_fixtures";

const ROOT = resolve(__dirname, "../..");
const ZTS_BIN = join(ROOT, "zig-out/bin/zts");
const BASELINE_PATH = join(__dirname, "baselines", "mangler-property.json");

const BUNDLE_SIZE_TOLERANCE = 0.01; // ±1%
const NAME_LENGTH_TOLERANCE = 0.01; // ±1%
const RESERVED_POOL_ABS = 2;

interface ManglerStats {
  slot_count: number;
  slot_name_length_sum: number;
  name_counter_final: number;
  reserved_size: number;
  renamed_symbol_count: number;
}

interface NestedEntry {
  module_path: string;
  stats: ManglerStats;
}

interface ManglerReport {
  top_level: ManglerStats;
  top_level_reserved_pool: number;
  nested: NestedEntry[];
  bundle_size_bytes: number;
  totals: ManglerStats;
}

interface FixtureResult {
  name: string;
  report: ManglerReport;
  nested_module_count: number;
  nested_totals: ManglerStats;
}

interface Baseline {
  version: number;
  generated_at: string;
  fixtures: FixtureResult[];
}

type Fixture = CommonFixture;
const fixtures: Fixture[] = COMMON_FIXTURES;

function emptyStats(): ManglerStats {
  return {
    slot_count: 0,
    slot_name_length_sum: 0,
    name_counter_final: 0,
    reserved_size: 0,
    renamed_symbol_count: 0,
  };
}

function sumNested(report: ManglerReport): ManglerStats {
  const totals = emptyStats();
  for (const e of report.nested) {
    totals.slot_count += e.stats.slot_count;
    totals.slot_name_length_sum += e.stats.slot_name_length_sum;
    totals.renamed_symbol_count += e.stats.renamed_symbol_count;
    totals.reserved_size += e.stats.reserved_size;
  }
  return totals;
}

function runFixture(f: Fixture): FixtureResult {
  const dir = mkdtempSync(join(tmpdir(), `zts-mangle-${f.name}-`));
  const entryFile = join(__dirname, `_mangle_entry_${f.name}.ts`);
  writeFileSync(entryFile, f.entry);
  try {
    const outFile = join(dir, "zts.js");
    const reportFile = join(dir, "report.json");
    const args = [
      "--bundle",
      entryFile,
      "-o",
      outFile,
      "--minify",
      `--platform=${f.platform ?? "node"}`,
      `--mangle-report=${reportFile}`,
    ];
    const r = spawnSync(ZTS_BIN, args, { encoding: "utf8", timeout: 180_000 });
    if (r.status !== 0) {
      throw new Error(`zts failed (${r.status}): ${r.stderr}`);
    }
    const report: ManglerReport = JSON.parse(readFileSync(reportFile, "utf8"));
    return {
      name: f.name,
      report,
      nested_module_count: report.nested.length,
      nested_totals: sumNested(report),
    };
  } finally {
    rmSync(dir, { recursive: true, force: true });
    try {
      rmSync(entryFile);
    } catch {}
  }
}

function formatStats(s: ManglerStats): string {
  return `slots=${s.slot_count} nameLen=${s.slot_name_length_sum} rename=${s.renamed_symbol_count}`;
}

function printFixture(r: FixtureResult): void {
  console.log(`\n## ${r.name}`);
  console.log(`  bundle_size: ${r.report.bundle_size_bytes} B`);
  console.log(`  top:    ${formatStats(r.report.top_level)} (pool=${r.report.top_level_reserved_pool})`);
  console.log(`  nested: (${r.nested_module_count} mod) ${formatStats(r.nested_totals)}`);
}

type Check = { ok: boolean; label: string; detail: string };

function checkFixture(baseline: FixtureResult, current: FixtureResult): Check[] {
  const checks: Check[] = [];
  const size_delta = current.report.bundle_size_bytes - baseline.report.bundle_size_bytes;
  const size_ratio =
    baseline.report.bundle_size_bytes === 0 ? 0 : size_delta / baseline.report.bundle_size_bytes;
  checks.push({
    ok: Math.abs(size_ratio) <= BUNDLE_SIZE_TOLERANCE,
    label: `bundle_size(${baseline.name})`,
    detail: `${baseline.report.bundle_size_bytes} -> ${current.report.bundle_size_bytes} (${(size_ratio * 100).toFixed(2)}%)`,
  });

  const b_nl = baseline.report.totals.slot_name_length_sum;
  const c_nl = current.report.totals.slot_name_length_sum;
  const nl_ratio = b_nl === 0 ? 0 : (c_nl - b_nl) / b_nl;
  checks.push({
    ok: Math.abs(nl_ratio) <= NAME_LENGTH_TOLERANCE,
    label: `name_length_sum(${baseline.name})`,
    detail: `${b_nl} -> ${c_nl} (${(nl_ratio * 100).toFixed(2)}%)`,
  });

  const b_pool = baseline.report.top_level_reserved_pool;
  const c_pool = current.report.top_level_reserved_pool;
  checks.push({
    ok: Math.abs(c_pool - b_pool) <= RESERVED_POOL_ABS,
    label: `reserved_pool(${baseline.name})`,
    detail: `${b_pool} -> ${c_pool} (Δ${c_pool - b_pool})`,
  });

  return checks;
}

function main(): void {
  const writeBaseline = process.argv.includes("--write");

  const results: FixtureResult[] = [];
  for (const f of fixtures) {
    try {
      const r = runFixture(f);
      results.push(r);
      printFixture(r);
    } catch (e) {
      console.error(`\n## ${f.name}: FAIL — ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  if (writeBaseline) {
    mkdirSync(join(__dirname, "baselines"), { recursive: true });
    const bl: Baseline = {
      version: 1,
      generated_at: new Date().toISOString(),
      fixtures: results,
    };
    writeFileSync(BASELINE_PATH, JSON.stringify(bl, null, 2) + "\n");
    console.log(`\nBaseline written: ${BASELINE_PATH}`);
    return;
  }

  let baseline: Baseline;
  try {
    baseline = JSON.parse(readFileSync(BASELINE_PATH, "utf8"));
  } catch {
    console.log(`\n(no baseline at ${BASELINE_PATH} — run with --write to create)`);
    return;
  }

  const baselineByName = new Map(baseline.fixtures.map((f) => [f.name, f]));
  let failed = 0;
  console.log("\n# Baseline comparison\n");
  for (const cur of results) {
    const base = baselineByName.get(cur.name);
    if (!base) {
      console.log(`- ${cur.name}: no baseline entry (add with --write)`);
      continue;
    }
    for (const c of checkFixture(base, cur)) {
      const mark = c.ok ? "✓" : "✗";
      console.log(`- ${mark} ${c.label}: ${c.detail}`);
      if (!c.ok) failed += 1;
    }
  }
  if (failed > 0) {
    console.error(`\n${failed} check(s) failed.`);
    process.exit(1);
  }
  console.log("\nAll property checks within tolerance.");
}

main();
