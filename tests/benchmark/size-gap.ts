#!/usr/bin/env bun
/**
 * Size-gap diagnostics for small package smoke benchmarks.
 *
 * Runs smoke.ts with preserved outputs, then compares ZTS against the smallest
 * successful baseline bundle to surface likely size-gap causes.
 */

import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";

import type { BundlerResult, SmokeResult } from "./smoke.ts";

const ROOT = resolve(__dirname, "../..");

type BundlerName = "esbuild" | "rolldown" | "rspack";

interface Candidate {
  value: string;
  ztsCount: number;
}

interface CjsExportAudit {
  sourceFileCount: number;
  patternCounts: Record<CjsExportPattern, number>;
  remainingMarkers: Candidate[];
  removedMarkerCandidates: Candidate[];
}

type CjsExportPattern =
  | "exports.x ="
  | "module.exports.x ="
  | "module.exports = { ... }"
  | "Object.defineProperty(..., { value })"
  | "Object.defineProperty(..., { value: member })"
  | "Object.defineProperty(..., { get })";

const cjsExportPatterns: CjsExportPattern[] = [
  "exports.x =",
  "module.exports.x =",
  "module.exports = { ... }",
  "Object.defineProperty(..., { value })",
  "Object.defineProperty(..., { value: member })",
  "Object.defineProperty(..., { get })",
];

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

function runSmoke(projects: string[], keepDir: string, jsonPath: string): SmokeResult[] {
  const r = spawnSync(
    "bun",
    [
      "run",
      "tests/benchmark/smoke.ts",
      `--filter=${projects.join(",")}`,
      `--keep-output=${keepDir}`,
      `--json=${jsonPath}`,
    ],
    {
      cwd: ROOT,
      stdio: "pipe",
      timeout: 600000,
    },
  );
  if (r.status !== 0) {
    throw new Error(
      `smoke.ts failed for ${projects.join(",")}\n${r.stdout?.toString()}\n${r.stderr?.toString()}`,
    );
  }
  const report = JSON.parse(readFileSync(jsonPath, "utf-8"));
  return projects.map((project) => {
    const exact = report.results.find((entry: SmokeResult) => entry.project === project);
    if (!exact) {
      throw new Error(`smoke.ts did not produce a result for ${project}`);
    }
    return exact;
  });
}

function readOutput(result?: BundlerResult): string {
  if (!result?.outputPath || !existsSync(result.outputPath)) return "";
  return readFileSync(result.outputPath, "utf-8");
}

function smallestBaseline(
  result: SmokeResult,
): { name: BundlerName; result: BundlerResult } | null {
  const candidates: { name: BundlerName; result: BundlerResult }[] = [
    { name: "esbuild", result: result.esbuild },
    { name: "rolldown", result: result.rolldown },
    { name: "rspack", result: result.rspack },
  ].filter((c) => c.result.build && c.result.size > 0);
  if (candidates.length === 0) return null;
  return candidates.reduce((best, current) =>
    current.result.size < best.result.size ? current : best,
  );
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

function increment(map: Map<string, number>, value: string): void {
  map.set(value, (map.get(value) ?? 0) + 1);
}

function countCjsExportPatterns(text: string): Record<CjsExportPattern, number> {
  return {
    "exports.x =": [...text.matchAll(/(^|[^\w$.])exports\.[A-Za-z_$][\w$]*\s*=/gm)].length,
    "module.exports.x =": [...text.matchAll(/\bmodule\.exports\.[A-Za-z_$][\w$]*\s*=/g)].length,
    "module.exports = { ... }": [...text.matchAll(/\bmodule\.exports\s*=\s*\{/g)].length,
    "Object.defineProperty(..., { value })": [
      ...text.matchAll(
        /\bObject\.defineProperty\s*\(\s*(?:exports|module\.exports)\s*,\s*(["'`])(?:\\.|(?!\1).)+\1\s*,\s*\{[^}]*\bvalue\b/g,
      ),
    ].length,
    "Object.defineProperty(..., { value: member })": [
      ...text.matchAll(
        /\bObject\.defineProperty\s*\(\s*(?:exports|module\.exports)\s*,\s*(["'`])(?:\\.|(?!\1).)+\1\s*,\s*\{[^}]*\bvalue\s*:\s*[A-Za-z_$][\w$]*\.[A-Za-z_$][\w$]*/g,
      ),
    ].length,
    "Object.defineProperty(..., { get })": [
      ...text.matchAll(
        /\bObject\.defineProperty\s*\(\s*(?:exports|module\.exports)\s*,\s*(["'`])(?:\\.|(?!\1).)+\1\s*,\s*\{[^}]*\bget\b/g,
      ),
    ].length,
  };
}

function collectCjsExportMarkers(text: string): Map<string, number> {
  const markers = new Map<string, number>();

  for (const match of text.matchAll(/(^|[^\w$.])exports\.([A-Za-z_$][\w$]*)\s*=/gm)) {
    increment(markers, `exports.${match[2]} =`);
  }
  for (const match of text.matchAll(/\bmodule\.exports\.([A-Za-z_$][\w$]*)\s*=/g)) {
    increment(markers, `module.exports.${match[1]} =`);
  }
  for (const _match of text.matchAll(/\bmodule\.exports\s*=\s*\{/g)) {
    increment(markers, "module.exports = {");
  }
  for (const match of text.matchAll(
    /\bObject\.defineProperty\s*\(\s*(exports|module\.exports)\s*,\s*(["'`])((?:\\.|(?!\2).)+)\2\s*,\s*\{[^}]*\bvalue\b/g,
  )) {
    increment(
      markers,
      `Object.defineProperty(${match[1]}, ${JSON.stringify(match[3])}, { value })`,
    );
  }

  return markers;
}

function readJavaScriptFiles(dir: string): { path: string; content: string }[] {
  if (!existsSync(dir) || !statSync(dir).isDirectory()) return [];

  const files: { path: string; content: string }[] = [];
  const visit = (current: string) => {
    for (const entry of readdirSync(current, { withFileTypes: true })) {
      if (entry.name === "node_modules" || entry.name === ".bin") continue;
      const fullPath = join(current, entry.name);
      if (entry.isDirectory()) {
        visit(fullPath);
      } else if (entry.isFile() && /\.(?:cjs|js|mjs)$/.test(entry.name)) {
        files.push({ path: fullPath, content: readFileSync(fullPath, "utf-8") });
      }
    }
  };
  visit(dir);
  return files.sort((a, b) => a.path.localeCompare(b.path));
}

function packageSourceFiles(project: string): { path: string; content: string }[] {
  const candidates = [
    join(ROOT, "tests/benchmark/node_modules", project),
    join(ROOT, "node_modules", project),
  ];
  for (const candidate of candidates) {
    const files = readJavaScriptFiles(candidate);
    if (files.length > 0) return files;
  }
  return [];
}

function cjsExportAudit(project: string, zts: string): CjsExportAudit {
  const sourceFiles = packageSourceFiles(project);
  const source = sourceFiles.map((file) => file.content).join("\n");
  const sourceMarkers = collectCjsExportMarkers(source);
  const ztsMarkers = collectCjsExportMarkers(zts);

  const patternCounts = countCjsExportPatterns(source);
  const remainingMarkers = [...ztsMarkers]
    .map(([value, ztsCount]) => ({ value, ztsCount }))
    .sort((a, b) => b.ztsCount - a.ztsCount || a.value.localeCompare(b.value))
    .slice(0, 12);
  const removedMarkerCandidates = [...sourceMarkers]
    .filter(([value]) => !ztsMarkers.has(value))
    .map(([value, ztsCount]) => ({ value, ztsCount }))
    .sort((a, b) => b.ztsCount - a.ztsCount || a.value.localeCompare(b.value))
    .slice(0, 12);

  return {
    sourceFileCount: sourceFiles.length,
    patternCounts,
    remainingMarkers,
    removedMarkerCandidates,
  };
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
    .map((raw) => ({
      value: JSON.stringify(raw).slice(0, 80),
      ztsCount: countOccurrences(zts, raw),
      weight: raw.length * countOccurrences(zts, raw),
    }))
    .sort((a, b) => b.weight - a.weight)
    .slice(0, 8)
    .map(({ value, ztsCount }) => ({ value, ztsCount }));
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
  const re = /^(?:function|class|const|let|var)\s+([A-Za-z_$][\w$]*)\b/gm;
  const baselineNames = new Set<string>();
  for (const match of baseline.matchAll(re)) {
    baselineNames.add(match[1]);
  }
  const names = new Set<string>();
  for (const match of zts.matchAll(re)) {
    if (!baselineNames.has(match[1])) names.add(match[1]);
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

function formatPatternCounts(patternCounts: Record<CjsExportPattern, number>): string {
  return cjsExportPatterns.map((pattern) => `  - ${pattern}: ${patternCounts[pattern]}`).join("\n");
}

const projects = parseProjects();
const tempDir = mkdtempSync(join(tmpdir(), "zts-size-gap-"));
const keepDir = join(tempDir, "outputs");
const jsonPath = join(tempDir, "smoke.json");

try {
  const results = runSmoke(projects, keepDir, jsonPath);

  console.log("# ZTS Size Gap Diagnostics");
  console.log(`Projects: ${projects.join(", ")}`);

  for (const result of results) {
    const baseline = smallestBaseline(result);
    console.log(`\n## ${result.project}`);
    if (!baseline) {
      console.log("No successful baseline output.");
      continue;
    }

    const zts = readOutput(result.zts);
    const base = readOutput(baseline.result);
    const ratio = result.zts.size > 0 ? result.zts.size / baseline.result.size : 0;

    console.log(
      `ZTS: ${result.zts.size} bytes | Baseline: ${baseline.name} ${baseline.result.size} bytes | Ratio: ${ratio.toFixed(2)}x | Output: ${result.outputMatch ? "MATCH" : "DIFF"}`,
    );
    console.log(
      `Files: ${basename(result.zts.outputPath ?? "")} vs ${basename(baseline.result.outputPath ?? "")}`,
    );

    console.log("\nZTS-only strings");
    console.log(formatCandidates(ztsOnlyStrings(zts, base)));
    console.log("\nWrapper markers");
    console.log(formatCandidates(wrapperMarkers(zts, base)));
    console.log("\nTop-level declarations");
    console.log(formatCandidates(topLevelDeclarations(zts, base)));
    const audit = cjsExportAudit(result.project, zts);
    console.log("\nCJS export pattern audit");
    console.log(`  Source JS files: ${audit.sourceFileCount}`);
    console.log("  Pattern counts:");
    console.log(formatPatternCounts(audit.patternCounts));
    console.log("  Remaining ZTS export markers:");
    console.log(formatCandidates(audit.remainingMarkers));
    console.log("  Removed dead marker candidates:");
    console.log(formatCandidates(audit.removedMarkerCandidates));
  }
} finally {
  if (!process.argv.includes("--keep-temp")) {
    rmSync(tempDir, { recursive: true, force: true });
  }
}
