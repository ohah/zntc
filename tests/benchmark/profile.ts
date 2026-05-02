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

function generateImportBearingTS(lines: number): string {
  const parts: string[] = [
    `import { Foo, Bar, Baz, Qux, type Shape } from "./lib";`,
    `type LocalShape = Shape | Foo;`,
  ];
  let i = 0;
  while (parts.length < lines) {
    parts.push(`export type Item${i} = Foo & Shape & { readonly id${i}: string };`);
    parts.push(`export interface Box${i} { value: Item${i}; next?: Box${i}; }`);
    parts.push(`type Mapper${i}<T extends Foo> = (input: T | Shape) => Box${i};`);
    parts.push(`export type Result${i} = ReturnType<Mapper${i}<Foo>> | LocalShape;`);
    parts.push(`export const value${i} = Bar(${i});`);
    parts.push(`{ const Foo = value${i}; Foo; }`);
    parts.push(`try { Baz(value${i}); } catch (Baz) { Baz; }`);
    parts.push(`export const fn${i} = (Qux = Foo) => Qux;`);
    i++;
  }
  return parts.slice(0, lines).join("\n");
}

function median(times: number[]): number {
  const sorted = [...times].sort((a, b) => a - b);
  return Math.round(sorted[Math.floor(sorted.length / 2)]);
}

function measure(bin: string, args: string[], env?: Record<string, string>): number {
  const times: number[] = [];
  const spawnEnv = env ? { ...process.env, ...env } : undefined;
  // warmup
  spawnSync(bin, args, { stdio: "pipe", timeout: 30000, env: spawnEnv });
  for (let i = 0; i < ITERATIONS; i++) {
    const start = performance.now();
    spawnSync(bin, args, { stdio: "pipe", timeout: 30000, env: spawnEnv });
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

console.log("\nZTS Fast Path A/B — import-bearing TS strip");
const fastScales = [25_000, 50_000, 100_000];
console.log(`| Lines | Size (KB) | fast on (ms) | fast off (ms) | delta (ms) | ratio |`);
console.log(`| --- | --- | --- | --- | --- | --- |`);

for (const lines of fastScales) {
  const source = generateImportBearingTS(lines);
  const inputFile = join(dir, `binding_lite_${lines}.ts`);
  const fastOut = join(dir, `out_fast_on_${lines}.js`);
  const fullOut = join(dir, `out_fast_off_${lines}.js`);
  writeFileSync(inputFile, source);

  const fastOn = measure(ZTS_BIN, [inputFile, "-o", fastOut]);
  const fastOff = measure(ZTS_BIN, [inputFile, "-o", fullOut], {
    ZTS_DISABLE_TRANSPILE_FAST_PATH: "1",
  });
  const delta = fastOff - fastOn;
  const ratio = fastOn === 0 ? "n/a" : `${(fastOff / fastOn).toFixed(2)}x`;

  console.log(
    `| ${lines} | ${Math.round(source.length / 1024)} | ${fastOn} | ${fastOff} | ${delta} | ${ratio} |`,
  );
}

rmSync(dir, { recursive: true, force: true });
console.log("\n(ms가 파일 크기에 비례하면 O(n), 제곱으로 증가하면 O(n²))");
