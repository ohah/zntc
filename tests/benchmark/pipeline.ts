#!/usr/bin/env bun
/**
 * ZTS Pipeline Profiler — 파이프라인 단계별 성능 측정
 *
 * ZTS의 --timing 옵션으로 scan/parse/semantic/transform/codegen
 * 각 단계의 소요 시간을 패턴별 + 규모별로 측정한다.
 * esbuild와의 벽시계 시간 비교도 포함.
 */

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const ROOT = resolve(__dirname, "../..");
const ZTS_BIN = join(ROOT, "zig-out/bin/zts");
const ESBUILD_BIN = join(ROOT, "node_modules/.bin/esbuild");
const ITERATIONS = 5;

// ============================================================
// Fixture generators — 패턴별 TS 코드 생성
// ============================================================

type PatternName = "simple" | "expr" | "string" | "object" | "react";

function generateSimple(lines: number): string {
  const parts: string[] = [];
  for (let i = 0; i < lines; i++) {
    parts.push(`const v${i}: number = ${i} + Math.random();`);
  }
  return parts.join("\n");
}

function generateExpr(lines: number): string {
  const parts: string[] = [];
  for (let i = 0; i < lines; i++) {
    parts.push(
      `const e${i} = ((${i} + ${i + 1}) * (${i + 2} - ${i + 3})) / ((${i + 4} % ${i + 5}) || 1);`,
    );
  }
  return parts.join("\n");
}

function generateString(lines: number): string {
  const parts: string[] = [];
  for (let i = 0; i < lines; i++) {
    parts.push(
      `const s${i} = "hello world ${i} this is a longer string with special chars \\n\\t";`,
    );
  }
  return parts.join("\n");
}

function generateObject(lines: number): string {
  const parts: string[] = [];
  // 절반은 interface, 절반은 object literal
  const count = Math.floor(lines / 2);
  for (let i = 0; i < count; i++) {
    parts.push(`interface I${i} { a${i}: string; b${i}: number; }`);
    parts.push(`const o${i}: I${i} = { a${i}: "v", b${i}: ${i} };`);
  }
  return parts.join("\n");
}

function generateReact(lines: number): string {
  const parts: string[] = [
    'import React, { useState, useCallback, createElement } from "react";',
    "",
  ];
  // 각 컴포넌트 ~5줄 → lines/5 컴포넌트
  const count = Math.max(1, Math.floor(lines / 5));
  for (let i = 0; i < count; i++) {
    parts.push(`interface Props${i} { name${i}: string; count${i}: number; }`);
    parts.push(`const Comp${i}: React.FC<Props${i}> = ({ name${i}, count${i} }) => {`);
    parts.push(`  const [s${i}, setS${i}] = useState(count${i});`);
    parts.push(`  const handler${i} = useCallback(() => setS${i}(s${i} + 1), [s${i}]);`);
    parts.push(`  return createElement("div", { onClick: handler${i} }, name${i}, String(s${i}));`);
    parts.push(`};`);
  }
  return parts.join("\n");
}

const GENERATORS: Record<PatternName, (lines: number) => string> = {
  simple: generateSimple,
  expr: generateExpr,
  string: generateString,
  object: generateObject,
  react: generateReact,
};

// ============================================================
// Timing parser — ZTS `--profile=all --profile-format=json` stderr 파싱
// (기존 `--timing` 은 제거됨 — #1672 D2 profile infrastructure)
// ============================================================

interface PipelineTiming {
  scan: number;
  parse: number;
  semantic: number;
  transform: number;
  codegen: number;
  total: number;
}

interface ProfileJson {
  profile_version: number;
  total_ms: number;
  level: string;
  phases: Record<string, { total_ms: number; count: number; pct: number }>;
}

function parseTiming(stderr: string): PipelineTiming | null {
  // `--profile-format=json` 은 `{ ... }` JSON 블록을 stderr 로 출력한다.
  const start = stderr.indexOf("{");
  if (start < 0) return null;
  const json = stderr.slice(start);
  let data: ProfileJson;
  try {
    data = JSON.parse(json);
  } catch {
    return null;
  }
  const get = (name: string): number => data.phases[name]?.total_ms ?? 0;
  return {
    scan: get("scan"),
    parse: get("parse"),
    semantic: get("semantic"),
    transform: get("transform"),
    codegen: get("codegen"),
    total: data.total_ms,
  };
}

// ============================================================
// Measurement helpers
// ============================================================

function median(values: number[]): number {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length / 2)];
}

function medianTiming(timings: PipelineTiming[]): PipelineTiming {
  const keys: (keyof PipelineTiming)[] = [
    "scan",
    "parse",
    "semantic",
    "transform",
    "codegen",
    "total",
  ];
  const result: Record<string, number> = {};
  for (const key of keys) {
    result[key] = median(timings.map((t) => t[key]));
  }
  return result as unknown as PipelineTiming;
}

function measureZtsTiming(inputFile: string, outFile: string): PipelineTiming | null {
  const timings: PipelineTiming[] = [];
  const profileArgs = ["--profile=all", "--profile-format=json"];

  // warmup
  spawnSync(ZTS_BIN, [inputFile, ...profileArgs, "-o", outFile], {
    stdio: "pipe",
    timeout: 60000,
  });

  for (let i = 0; i < ITERATIONS; i++) {
    const result = spawnSync(ZTS_BIN, [inputFile, ...profileArgs, "-o", outFile], {
      stdio: "pipe",
      timeout: 60000,
    });
    const parsed = parseTiming(result.stderr?.toString() ?? "");
    if (!parsed) return null;
    timings.push(parsed);
  }

  return medianTiming(timings);
}

function measureWallTime(bin: string, args: string[]): number {
  const times: number[] = [];

  // warmup
  spawnSync(bin, args, { stdio: "pipe", timeout: 60000 });

  for (let i = 0; i < ITERATIONS; i++) {
    const start = performance.now();
    spawnSync(bin, args, { stdio: "pipe", timeout: 60000 });
    times.push(performance.now() - start);
  }

  return median(times);
}

// ============================================================
// Result types
// ============================================================

interface PipelineResult {
  pattern: PatternName;
  lines: number;
  sizeKB: number;
  timing: PipelineTiming;
}

interface WallTimeResult {
  pattern: PatternName;
  lines: number;
  sizeKB: number;
  ztsMs: number;
  esbuildMs: number;
}

// ============================================================
// Format helpers
// ============================================================

function fmt(ms: number): string {
  if (ms < 1) return ms.toFixed(3);
  if (ms < 10) return ms.toFixed(2);
  if (ms < 100) return ms.toFixed(1);
  return Math.round(ms).toString();
}

function fmtMBs(sizeKB: number, ms: number): string {
  if (ms <= 0) return "-";
  const mbPerSec = sizeKB / 1024 / (ms / 1000);
  return Math.round(mbPerSec).toString();
}

// ============================================================
// Main
// ============================================================

const LINE_COUNTS = [1000, 5000, 10000, 50000];
const PATTERNS: PatternName[] = ["simple", "expr", "string", "object", "react"];

const hasEsbuild = existsSync(ESBUILD_BIN);

console.log("ZTS Pipeline Profiler");
console.log(`  Iterations: ${ITERATIONS} (median)`);
console.log(`  Patterns: ${PATTERNS.join(", ")}`);
console.log(`  Scales: ${LINE_COUNTS.map((l) => `${l / 1000}K`).join(", ")} lines`);
console.log(`  esbuild: ${hasEsbuild ? "available" : "not found"}`);
console.log(`  Platform: ${process.platform} ${process.arch}\n`);

const dir = mkdtempSync(join(tmpdir(), "zts-pipeline-"));
const pipelineResults: PipelineResult[] = [];
const wallTimeResults: WallTimeResult[] = [];

for (const pattern of PATTERNS) {
  console.log(`--- Pattern: ${pattern} ---`);
  const gen = GENERATORS[pattern];

  for (const lines of LINE_COUNTS) {
    const source = gen(lines);
    const inputFile = join(dir, `${pattern}_${lines}.ts`);
    const outFile = join(dir, `${pattern}_${lines}.js`);
    writeFileSync(inputFile, source);
    const sizeKB = Math.round(Buffer.byteLength(source) / 1024);

    // ZTS --timing
    const timing = measureZtsTiming(inputFile, outFile);
    if (timing) {
      pipelineResults.push({ pattern, lines, sizeKB, timing });
      console.log(
        `  ${lines / 1000}K lines (${sizeKB} KB): ` +
          `total=${fmt(timing.total)}ms ` +
          `(scan=${fmt(timing.scan)} parse=${fmt(timing.parse)} ` +
          `semantic=${fmt(timing.semantic)} transform=${fmt(timing.transform)} ` +
          `codegen=${fmt(timing.codegen)})`,
      );
    } else {
      console.log(`  ${lines / 1000}K lines: FAILED (--timing parse error)`);
    }

    // Wall time: ZTS vs esbuild
    const ztsMs = measureWallTime(ZTS_BIN, [inputFile, "-o", outFile]);
    let esbuildMs = -1;
    if (hasEsbuild) {
      esbuildMs = measureWallTime(ESBUILD_BIN, [
        inputFile,
        `--outfile=${join(dir, `${pattern}_${lines}_es.js`)}`,
      ]);
    }
    wallTimeResults.push({ pattern, lines, sizeKB, ztsMs, esbuildMs });
  }

  console.log("");
}

// ============================================================
// Output — Pipeline stage breakdown
// ============================================================

console.log("===== Pipeline Stage Breakdown (ms, median) =====\n");

for (const pattern of PATTERNS) {
  const group = pipelineResults.filter((r) => r.pattern === pattern);
  if (group.length === 0) continue;

  console.log(`### ${pattern}\n`);
  console.log("| Lines | Size (KB) | scan | parse | semantic | transform | codegen | total |");
  console.log("|------:|----------:|-----:|------:|---------:|----------:|--------:|------:|");

  for (const r of group) {
    const t = r.timing;
    console.log(
      `| ${r.lines.toLocaleString()} | ${r.sizeKB} | ${fmt(t.scan)} | ` +
        `${fmt(t.parse)} | ${fmt(t.semantic)} | ${fmt(t.transform)} | ` +
        `${fmt(t.codegen)} | ${fmt(t.total)} |`,
    );
  }
  console.log("");
}

// ============================================================
// Output — Throughput (MB/s)
// ============================================================

console.log("===== Throughput by Pattern (MB/s, based on total time) =====\n");

console.log("| Pattern | 1K lines | 5K lines | 10K lines | 50K lines |");
console.log("|---------|----------|----------|-----------|-----------|");

for (const pattern of PATTERNS) {
  const group = pipelineResults.filter((r) => r.pattern === pattern);
  const cells = LINE_COUNTS.map((lines) => {
    const r = group.find((g) => g.lines === lines);
    return r ? fmtMBs(r.sizeKB, r.timing.total) : "-";
  });
  console.log(`| ${pattern} | ${cells.join(" | ")} |`);
}

console.log("");

// ============================================================
// Output — ZTS vs esbuild wall time
// ============================================================

console.log("===== ZTS vs esbuild (wall time, ms, median) =====\n");

console.log("| Pattern | Lines | Size (KB) | ZTS (ms) | esbuild (ms) | ratio |");
console.log("|---------|------:|----------:|---------:|-------------:|------:|");

for (const r of wallTimeResults) {
  const ratio = r.esbuildMs > 0 ? `${(r.ztsMs / r.esbuildMs).toFixed(2)}x` : "-";
  const esStr = r.esbuildMs > 0 ? fmt(r.esbuildMs) : "N/A";
  console.log(
    `| ${r.pattern} | ${r.lines.toLocaleString()} | ${r.sizeKB} | ` +
      `${fmt(r.ztsMs)} | ${esStr} | ${ratio} |`,
  );
}

console.log("");

// ============================================================
// Cleanup
// ============================================================

rmSync(dir, { recursive: true, force: true });
console.log("Done.");
