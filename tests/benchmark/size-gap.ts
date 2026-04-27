#!/usr/bin/env bun
/**
 * Size-gap diagnostics for small package smoke benchmarks.
 *
 * Runs smoke.ts with preserved outputs, then compares ZTS against the smallest
 * successful baseline bundle to surface likely size-gap causes.
 */

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, rmSync } from "node:fs";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";

const ROOT = resolve(__dirname, "../..");

type BundlerName = "esbuild" | "rolldown" | "rspack";

interface SmokeBundlerResult {
  build: boolean;
  size: number;
  outputPath?: string;
}

interface SmokeProjectResult {
  project: string;
  zts: SmokeBundlerResult;
  esbuild: SmokeBundlerResult;
  rolldown: SmokeBundlerResult;
  rspack: SmokeBundlerResult;
  outputMatch: boolean;
}

interface Candidate {
  value: string;
  ztsCount: number;
}

function parseProjects(): string[] {
  const arg = process.argv.find((a) => a.startsWith("--projects="));
  if (!arg) {
    return ["safe-buffer", "cookie", "path-to-regexp"];
  }
  return arg
    .slice("--projects=".length)
    .split(",")
    .map((p) => p.trim())
    .filter(Boolean);
}

function runSmoke(projects: string[], keepDir: string, jsonPath: string): SmokeProjectResult[] {
  const results: SmokeProjectResult[] = [];
  for (const project of projects) {
    const r = spawnSync(
      "bun",
      [
        "run",
        "tests/benchmark/smoke.ts",
        `--filter=${project}`,
        `--keep-output=${keepDir}`,
        `--json=${jsonPath}`,
      ],
      {
        cwd: ROOT,
        stdio: "pipe",
        timeout: 180000,
      },
    );
    if (r.status !== 0) {
      throw new Error(
        `smoke.ts failed for ${project}\n${r.stdout?.toString()}\n${r.stderr?.toString()}`,
      );
    }
    const report = JSON.parse(readFileSync(jsonPath, "utf-8"));
    const exact = report.results.find((entry: SmokeProjectResult) => entry.project === project);
    if (!exact) {
      throw new Error(`smoke.ts did not produce an exact result for ${project}`);
    }
    results.push(exact);
  }
  return results;
}

function readOutput(result?: SmokeBundlerResult): string {
  if (!result?.outputPath || !existsSync(result.outputPath)) return "";
  return readFileSync(result.outputPath, "utf-8");
}

function smallestBaseline(result: SmokeProjectResult): { name: BundlerName; result: SmokeBundlerResult } | null {
  const candidates: { name: BundlerName; result: SmokeBundlerResult }[] = [
    { name: "esbuild", result: result.esbuild },
    { name: "rolldown", result: result.rolldown },
    { name: "rspack", result: result.rspack },
  ].filter((c) => c.result.build && c.result.size > 0);
  if (candidates.length === 0) return null;
  return candidates.reduce((best, current) => (current.result.size < best.result.size ? current : best));
}

function countOccurrences(text: string, needle: string): number {
  if (needle.length === 0) return 0;
  let count = 0;
  let index = 0;
  while ((index = text.indexOf(needle, index)) !== -1) {
    count++;
    index += needle.length;
  }
  return count;
}

function ztsOnlyStrings(zts: string, baseline: string): Candidate[] {
  const strings = new Set<string>();
  const re = /(["'`])((?:\\.|(?!\1).){16,})\1/g;
  for (const match of zts.matchAll(re)) {
    const value = match[2];
    if (/^\s*$/.test(value) || baseline.includes(value)) continue;
    strings.add(value);
  }
  return [...strings]
    .map((value) => ({ value, ztsCount: countOccurrences(zts, value) }))
    .sort((a, b) => b.value.length * b.ztsCount - a.value.length * a.ztsCount)
    .slice(0, 8);
}

function wrapperMarkers(zts: string, baseline: string): Candidate[] {
  const markers = [
    "__commonJS",
    "__export",
    "__toESM",
    "__copyProps",
    "__reExport",
    "__toCommonJS",
    "module.exports",
    "Object.defineProperty",
    "__require",
  ];
  return markers
    .filter((marker) => zts.includes(marker) && !baseline.includes(marker))
    .map((value) => ({ value, ztsCount: countOccurrences(zts, value) }))
    .sort((a, b) => b.ztsCount - a.ztsCount);
}

function topLevelDeclarations(zts: string, baseline: string): Candidate[] {
  const names = new Set<string>();
  const re = /^(?:function|class|const|let|var)\s+([A-Za-z_$][\w$]*)\b/gm;
  for (const match of zts.matchAll(re)) {
    const name = match[1];
    const baselineDecl = new RegExp(`^(?:function|class|const|let|var)\\s+${name}\\b`, "m");
    if (!baselineDecl.test(baseline)) {
      names.add(name);
    }
  }
  return [...names]
    .map((value) => ({ value, ztsCount: countOccurrences(zts, value) }))
    .sort((a, b) => b.ztsCount - a.ztsCount)
    .slice(0, 12);
}

function formatCandidates(candidates: Candidate[]): string {
  if (candidates.length === 0) return "  - none";
  return candidates.map((c) => `  - ${c.value} (${c.ztsCount}x)`).join("\n");
}

const projects = parseProjects();
const tempDir = mkdtempSync(join(tmpdir(), "zts-size-gap-"));
const keepDir = join(tempDir, "outputs");
const jsonPath = join(tempDir, "smoke.json");

try {
  const results = runSmoke(projects, keepDir, jsonPath);

  console.log("# ZTS Size Gap Diagnostics\n");
  console.log(`Projects: ${projects.join(", ")}\n`);

  for (const result of results) {
    const baseline = smallestBaseline(result);
    if (!baseline) {
      console.log(`## ${result.project}\n`);
      console.log("No successful baseline output.\n");
      continue;
    }

    const zts = readOutput(result.zts);
    const base = readOutput(baseline.result);
    const ratio = result.zts.size > 0 ? result.zts.size / baseline.result.size : 0;

    console.log(`## ${result.project}\n`);
    console.log(
      `ZTS: ${result.zts.size} bytes | Baseline: ${baseline.name} ${baseline.result.size} bytes | Ratio: ${ratio.toFixed(2)}x | Output: ${result.outputMatch ? "MATCH" : "DIFF"}`,
    );
    console.log(
      `Files: ${basename(result.zts.outputPath ?? "")} vs ${basename(baseline.result.outputPath ?? "")}\n`,
    );

    console.log("ZTS-only strings");
    console.log(formatCandidates(ztsOnlyStrings(zts, base)));
    console.log("\nWrapper markers");
    console.log(formatCandidates(wrapperMarkers(zts, base)));
    console.log("\nTop-level declarations");
    console.log(formatCandidates(topLevelDeclarations(zts, base)));
    console.log("");
  }
} finally {
  if (!process.argv.includes("--keep-temp")) {
    rmSync(tempDir, { recursive: true, force: true });
  }
}
