#!/usr/bin/env bun
/**
 * ZTS Scaling Profiler — 파일 크기별 스케일링 비교
 *
 * 모든 도구의 파일 크기 대비 성능 스케일링을 측정한다.
 */

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const ROOT = resolve(__dirname, "../..");
const ZTS_BIN = join(ROOT, "zig-out/bin/zts");
const ITERATIONS = 10;

function findBin(name: string): string | null {
  const local = join(__dirname, "node_modules/.bin", name);
  if (existsSync(local)) return local;
  const root = join(ROOT, "node_modules/.bin", name);
  if (existsSync(root)) return root;
  return null;
}

function generateTS(lines: number): string {
  const parts: string[] = [];
  for (let i = 0; i < lines; i++) {
    parts.push(`export const value${i}: number = ${i};`);
    if (i % 100 === 0) {
      parts.push(`export function compute${i}(x: number): number { return x * ${i}; }`);
    }
  }
  return parts.join("\n");
}

function median(times: number[]): number {
  const sorted = [...times].sort((a, b) => a - b);
  return Math.round(sorted[Math.floor(sorted.length / 2)]);
}

function measure(bin: string, args: string[]): number {
  const times: number[] = [];
  // warmup
  spawnSync(bin, args, { stdio: "pipe", timeout: 30000 });
  for (let i = 0; i < ITERATIONS; i++) {
    const start = performance.now();
    spawnSync(bin, args, { stdio: "pipe", timeout: 30000 });
    times.push(performance.now() - start);
  }
  return median(times);
}

const scales = [100, 500, 1000, 2000, 5000, 10000];
const dir = mkdtempSync(join(tmpdir(), "zts-profile-"));

const esbuildBin = findBin("esbuild");
const swcBin = findBin("swc");

console.log("ZTS Scaling Profiler — All Tools");
console.log(`  Iterations: ${ITERATIONS} (median)`);
console.log(`  Platform: ${process.platform} ${process.arch}\n`);

// Header
const tools = ["ZTS"];
if (esbuildBin) tools.push("esbuild");
tools.push("Bun");
if (swcBin) tools.push("SWC");
tools.push("oxc (node)");

const header = ["Lines", "Size (KB)", ...tools.map((t) => `${t} (ms)`)];
console.log(`| ${header.join(" | ")} |`);
console.log(`| ${header.map(() => "---").join(" | ")} |`);

for (const lines of scales) {
  const source = generateTS(lines);
  const inputFile = join(dir, `input_${lines}.ts`);
  writeFileSync(inputFile, source);
  const sizeKB = Math.round(source.length / 1024);

  const row: (string | number)[] = [lines, sizeKB];

  // ZTS
  row.push(measure(ZTS_BIN, [inputFile, "-o", join(dir, `out_zts_${lines}.js`)]));

  // esbuild
  if (esbuildBin) {
    row.push(
      measure(esbuildBin, [
        inputFile,
        `--outfile=${join(dir, `out_es_${lines}.js`)}`,
        "--loader=ts",
      ]),
    );
  }

  // Bun
  row.push(
    measure("bun", [
      "build",
      inputFile,
      "--no-bundle",
      "--outfile",
      join(dir, `out_bun_${lines}.js`),
    ]),
  );

  // SWC
  if (swcBin) {
    row.push(measure(swcBin, [inputFile, "-o", join(dir, `out_swc_${lines}.js`)]));
  }

  // oxc (node)
  row.push(
    measure("node", [
      "-e",
      `const {transformSync}=require('oxc-transform');const fs=require('fs');` +
        `const code=fs.readFileSync('${inputFile}','utf8');` +
        `transformSync('input.ts',code,{sourceType:'module'})`,
    ]),
  );

  console.log(`| ${row.join(" | ")} |`);
}

rmSync(dir, { recursive: true, force: true });
console.log("\n(ms가 파일 크기에 비례하면 O(n), 제곱으로 증가하면 O(n²))");
