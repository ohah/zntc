#!/usr/bin/env bun
/**
 * ZTS Benchmark Suite — 공정한 다규모 성능 비교
 *
 * 모든 도구를 CLI 바이너리 직접 호출 (npx 오버헤드 제거).
 * 소규모/중규모/대규모 시나리오로 스케일 특성 측정.
 */

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync, mkdirSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const ROOT = resolve(__dirname, "../..");
const ZTS_BIN = join(ROOT, "zig-out/bin/zts");
const BIN = join(ROOT, "node_modules/.bin");
const ITERATIONS = 5;

// ============================================================
// CLI 바이너리 경로
// ============================================================

function findBin(name: string): string | null {
  const local = join(__dirname, "node_modules/.bin", name);
  if (existsSync(local)) return local;
  const root = join(BIN, name);
  if (existsSync(root)) return root;
  return null;
}

// ============================================================
// Fixture generation
// ============================================================

function generateTS(lines: number): string {
  const parts: string[] = ['import { helper } from "./helper";', ""];
  for (let i = 0; i < lines; i++) {
    parts.push(`export const value${i}: number = ${i} + helper(${i});`);
    if (i % 50 === 0) {
      parts.push(`export function compute${i}(x: number): number { return x * ${i}; }`);
    }
  }
  parts.push(`export default function main() { return value0; }`);
  return parts.join("\n");
}

function generateHelper(): string {
  return `export function helper(n: number): number { return n * 2; }\n`;
}

function generateProject(dir: string, fileCount: number) {
  mkdirSync(join(dir, "src"), { recursive: true });

  for (let i = 0; i < fileCount - 1; i++) {
    writeFileSync(
      join(dir, "src", `mod${i}.ts`),
      `export const val${i} = ${i};\nexport function fn${i}(x: number) { return x + ${i}; }\n`,
    );
  }

  const imports = Array.from(
    { length: fileCount - 1 },
    (_, i) => `import { val${i}, fn${i} } from './mod${i}';`,
  ).join("\n");
  const usage = Array.from({ length: fileCount - 1 }, (_, i) => `fn${i}(val${i})`).join(" + ");
  writeFileSync(join(dir, "src", "index.ts"), `${imports}\nconsole.log(${usage});\n`);

  writeFileSync(
    join(dir, "tsconfig.json"),
    JSON.stringify({
      compilerOptions: {
        target: "es2020",
        module: "esnext",
        moduleResolution: "bundler",
        strict: true,
      },
      include: ["src"],
    }),
  );
}

// ============================================================
// Runner
// ============================================================

interface BenchResult {
  tool: string;
  task: string;
  scale: string;
  avgMs: number;
  minMs: number;
  maxMs: number;
}

function runBench(name: string, task: string, scale: string, fn: () => void): BenchResult {
  const times: number[] = [];

  try {
    fn();
  } catch {
    return { tool: name, task, scale, avgMs: -1, minMs: -1, maxMs: -1 };
  }

  for (let i = 0; i < ITERATIONS; i++) {
    const start = performance.now();
    try {
      fn();
    } catch {
      return { tool: name, task, scale, avgMs: -1, minMs: -1, maxMs: -1 };
    }
    times.push(performance.now() - start);
  }

  return {
    tool: name,
    task,
    scale,
    avgMs: Math.round(times.reduce((a, b) => a + b) / times.length),
    minMs: Math.round(Math.min(...times)),
    maxMs: Math.round(Math.max(...times)),
  };
}

function execBin(bin: string, args: string[], cwd?: string) {
  spawnSync(bin, args, { cwd, stdio: "pipe", timeout: 120000 });
}

// ============================================================
// Transpile benchmarks (소/중/대)
// ============================================================

function benchTranspile(): BenchResult[] {
  const results: BenchResult[] = [];
  const scales = [
    { name: "small (100 lines)", lines: 100 },
    { name: "medium (1K lines)", lines: 1000 },
    { name: "large (5K lines)", lines: 5000 },
  ];

  const esbuildBin = findBin("esbuild");
  const swcBin = findBin("swc");

  for (const scale of scales) {
    const dir = mkdtempSync(join(tmpdir(), "zts-bench-"));
    const inputFile = join(dir, "input.ts");
    writeFileSync(inputFile, generateTS(scale.lines));
    writeFileSync(join(dir, "helper.ts"), generateHelper());

    console.log(`\n--- Transpile: ${scale.name} ---`);

    results.push(
      runBench("ZTS", "transpile", scale.name, () => {
        execBin(ZTS_BIN, [inputFile, "-o", join(dir, "out-zts.js")]);
      }),
    );

    if (esbuildBin) {
      results.push(
        runBench("esbuild", "transpile", scale.name, () => {
          execBin(esbuildBin, [
            inputFile,
            `--outfile=${join(dir, "out-esbuild.js")}`,
            "--loader=ts",
          ]);
        }),
      );
    }

    if (swcBin) {
      results.push(
        runBench("SWC", "transpile", scale.name, () => {
          execBin(swcBin, [inputFile, "-o", join(dir, "out-swc.js")]);
        }),
      );
    }

    results.push(
      runBench("oxc (node)", "transpile", scale.name, () => {
        execBin("node", [
          "-e",
          `const {transformSync}=require('oxc-transform');const fs=require('fs');` +
            `const code=fs.readFileSync('${inputFile}','utf8');` +
            `transformSync('input.ts',code,{sourceType:'module'})`,
        ]);
      }),
    );

    // Bun (transpile via bun build --no-bundle)
    results.push(
      runBench("Bun", "transpile", scale.name, () => {
        execBin("bun", ["build", inputFile, "--no-bundle", "--outfile", join(dir, "out-bun.js")]);
      }),
    );

    rmSync(dir, { recursive: true, force: true });
  }

  return results;
}

// ============================================================
// Bundle benchmarks (소/중/대)
// ============================================================

function benchBundle(): BenchResult[] {
  const results: BenchResult[] = [];
  const scales = [
    { name: "small (10 modules)", files: 10 },
    { name: "medium (50 modules)", files: 50 },
    { name: "large (200 modules)", files: 200 },
  ];

  const esbuildBin = findBin("esbuild");
  const rolldownBin = findBin("rolldown");
  const webpackBin = findBin("webpack");
  const rspackBin = findBin("rspack");

  for (const scale of scales) {
    const dir = mkdtempSync(join(tmpdir(), "zts-bench-bundle-"));
    generateProject(dir, scale.files);
    const entry = join(dir, "src", "index.ts");
    const outDir = join(dir, "dist");
    mkdirSync(outDir, { recursive: true });

    console.log(`\n--- Bundle: ${scale.name} ---`);

    results.push(
      runBench("ZTS", "bundle", scale.name, () => {
        execBin(ZTS_BIN, ["--bundle", entry, "-o", join(outDir, "zts.js")]);
      }),
    );

    if (esbuildBin) {
      results.push(
        runBench("esbuild", "bundle", scale.name, () => {
          execBin(esbuildBin, [
            entry,
            "--bundle",
            `--outfile=${join(outDir, "esbuild.js")}`,
            "--loader:.ts=ts",
          ]);
        }),
      );
    }

    // Bun bundle
    results.push(
      runBench("Bun", "bundle", scale.name, () => {
        execBin("bun", ["build", entry, "--outfile", join(outDir, "bun.js")]);
      }),
    );

    if (rolldownBin) {
      results.push(
        runBench("rolldown", "bundle", scale.name, () => {
          execBin(rolldownBin, [entry, "--dir", join(outDir, "rolldown")]);
        }),
      );
    }

    // webpack/rspack은 large에서만 (느려서)
    if (scale.files <= 50) {
      if (webpackBin) {
        const config = join(dir, "webpack.config.js");
        writeFileSync(
          config,
          `module.exports = {
  mode: 'production', entry: '${entry}',
  output: { path: '${outDir}', filename: 'webpack.js' },
  resolve: { extensions: ['.ts', '.js'] },
  module: { rules: [{ test: /\\.ts$/, use: 'ts-loader', exclude: /node_modules/ }] },
};`,
        );
        results.push(
          runBench("webpack", "bundle", scale.name, () => {
            execBin(webpackBin, ["--config", config], dir);
          }),
        );
      }

      if (rspackBin) {
        const config = join(dir, "rspack.config.js");
        writeFileSync(
          config,
          `module.exports = {
  mode: 'production', entry: '${entry}',
  output: { path: '${outDir}', filename: 'rspack.js' },
  resolve: { extensions: ['.ts', '.js'] },
  module: { rules: [{ test: /\\.ts$/, type: 'javascript/auto', use: { loader: 'builtin:swc-loader', options: { jsc: { parser: { syntax: 'typescript' } } } } }] },
};`,
        );
        results.push(
          runBench("rspack", "bundle", scale.name, () => {
            execBin(rspackBin, ["build", "--config", config], dir);
          }),
        );
      }
    }

    rmSync(dir, { recursive: true, force: true });
  }

  return results;
}

// ============================================================
// Output
// ============================================================

function printResults(results: BenchResult[]) {
  const tasks = [...new Set(results.map((r) => r.task))];
  for (const task of tasks) {
    const scales = [...new Set(results.filter((r) => r.task === task).map((r) => r.scale))];
    for (const scale of scales) {
      const group = results
        .filter((r) => r.task === task && r.scale === scale)
        .sort((a, b) => {
          if (a.avgMs === -1) return 1;
          if (b.avgMs === -1) return -1;
          return a.avgMs - b.avgMs;
        });

      console.log(`\n### ${task} — ${scale}`);
      console.log("| Tool | Avg (ms) | Min (ms) | Max (ms) | vs fastest |");
      console.log("|------|----------|----------|----------|------------|");
      const fastest = group.find((r) => r.avgMs > 0)?.avgMs ?? 1;
      for (const r of group) {
        const avg = r.avgMs === -1 ? "FAIL" : String(r.avgMs);
        const min = r.minMs === -1 ? "-" : String(r.minMs);
        const max = r.maxMs === -1 ? "-" : String(r.maxMs);
        const ratio = r.avgMs > 0 ? `${(r.avgMs / fastest).toFixed(1)}x` : "-";
        console.log(`| ${r.tool} | ${avg} | ${min} | ${max} | ${ratio} |`);
      }
    }
  }
}

// ============================================================
// Main
// ============================================================

const args = process.argv.slice(2);
const doTranspile = args.includes("--transpile") || args.includes("--all") || args.length === 0;
const doBundle = args.includes("--bundle") || args.includes("--all") || args.length === 0;

console.log("ZTS Benchmark Suite");
console.log(`  Iterations: ${ITERATIONS}`);
console.log("  Method: CLI binary direct execution (no npx overhead)");
console.log(`  Platform: ${process.platform} ${process.arch}`);

const allResults: BenchResult[] = [];

if (doTranspile) allResults.push(...benchTranspile());
if (doBundle) allResults.push(...benchBundle());

console.log("\n===== Results =====");
printResults(allResults);
