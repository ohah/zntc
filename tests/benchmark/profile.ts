#!/usr/bin/env bun
/**
 * ZTS Scaling Profiler — 파일 크기별 스케일링 비교
 *
 * 모든 도구의 파일 크기 대비 성능 스케일링을 측정한다.
 */

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ROOT, ZTS_BIN, findNodeModulesBin } from "./_runner";

const ITERATIONS = 10;

type PlanSample = {
  name: string;
  filename: string;
  source: string;
  args?: string[];
};

type PlanHit = {
  semantic: string;
  reason: string;
};

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

function tracePlan(sample: PlanSample, dir: string): PlanHit {
  const inputFile = join(dir, sample.filename);
  const outFile = join(dir, `${sample.name.replaceAll(/[^a-zA-Z0-9_-]/g, "_")}.js`);
  writeFileSync(inputFile, sample.source);
  const result = spawnSync(ZTS_BIN, [inputFile, ...(sample.args ?? []), "-o", outFile], {
    stdio: "pipe",
    timeout: 30000,
    env: { ...process.env, ZTS_DEBUG: "transform_plan" },
    encoding: "utf8",
  });
  const match = result.stderr.match(
    /\[transform_plan\]\s+file=.*?\s+semantic=([a-z_]+)\s+reason=([a-z_]+)/,
  );
  if (!match) {
    const prefix = result.status === 0 ? "missing" : "failed before";
    throw new Error(
      `${prefix} transform_plan trace for ${sample.name}: ${result.stderr.slice(0, 500)}`,
    );
  }
  return { semantic: match[1], reason: match[2] };
}

function formatPercent(count: number, total: number): string {
  return `${((count / total) * 100).toFixed(1)}%`;
}

function printPlanHitRates(dir: string): void {
  const samples: PlanSample[] = [
    {
      name: "simple-ts-strip",
      filename: "simple.ts",
      source: generateTS(1000),
    },
    {
      name: "binding-lite-named-import",
      filename: "binding-lite.ts",
      source: generateImportBearingTS(1000),
    },
    {
      name: "default-import",
      filename: "default-import.ts",
      source: `import Foo from "./lib";\nexport const value = Foo();\n`,
    },
    {
      name: "namespace-import",
      filename: "namespace-import.ts",
      source: `import * as Foo from "./lib";\nexport const value = Foo.run();\n`,
    },
    {
      name: "jsx",
      filename: "component.tsx",
      source: `import { Foo } from "./lib";\nexport const value = <Foo />;\n`,
    },
    {
      name: "enum-runtime",
      filename: "enum.ts",
      source: `import { Foo } from "./lib";\nenum Kind { A }\nexport const value = Foo;\n`,
    },
    {
      name: "minify-option",
      filename: "minify.ts",
      source: `import { Foo } from "./lib";\nexport const value = Foo();\n`,
      args: ["--minify"],
    },
    {
      name: "cjs-format",
      filename: "cjs.ts",
      source: `import { Foo } from "./lib";\nexport const value = Foo();\n`,
      args: ["--format=cjs"],
    },
    {
      name: "downlevel-target",
      filename: "downlevel.ts",
      source: `import { Foo } from "./lib";\nexport const value = () => Foo();\n`,
      args: ["--target=es5"],
    },
    {
      name: "top-level-shadow",
      filename: "shadow.ts",
      source: `import { Foo } from "./lib";\nconst Foo = 1;\nexport { Foo };\n`,
    },
    {
      name: "function-var-shadow",
      filename: "function-var-shadow.ts",
      source: `import { Foo, Bar } from "./lib";\nfunction f() { var Foo = Bar(); return Foo; }\nFoo();\n`,
    },
    {
      name: "function-expression-shadow",
      filename: "function-expression-shadow.ts",
      source: `import { Foo, Bar } from "./lib";\nconst fn = function Foo(value = Foo) { return value; };\nBar();\n`,
    },
    {
      name: "js-source",
      filename: "plain.js",
      source: `const value = 1;\n`,
    },
    {
      name: "flow-source",
      filename: "flow.js",
      source: `// @flow\nimport { Foo } from "./lib";\nexport const value: Foo = 1;\n`,
      args: ["--flow"],
    },
  ];

  const hits = new Map<string, PlanHit & { count: number }>();
  for (const sample of samples) {
    const hit = tracePlan(sample, dir);
    const key = `${hit.semantic}:${hit.reason}`;
    const current = hits.get(key);
    if (current) {
      current.count += 1;
    } else {
      hits.set(key, { ...hit, count: 1 });
    }
  }

  console.log("\nZTS TransformPlan Hit Rates — representative route roots");
  console.log(`| Semantic | Reason | Count | Share |`);
  console.log(`| --- | --- | --- | --- |`);
  const rows = [...hits.values()].sort((a, b) =>
    a.semantic === b.semantic
      ? a.reason.localeCompare(b.reason)
      : a.semantic.localeCompare(b.semantic),
  );
  for (const row of rows) {
    console.log(
      `| ${row.semantic} | ${row.reason} | ${row.count} | ${formatPercent(row.count, samples.length)} |`,
    );
  }
}

const scales = [100, 500, 1000, 2000, 5000, 10000];
const dir = mkdtempSync(join(tmpdir(), "zts-profile-"));

const esbuildBin = findNodeModulesBin("esbuild");
const swcBin = findNodeModulesBin("swc");

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

printPlanHitRates(dir);

rmSync(dir, { recursive: true, force: true });
console.log("\n(ms가 파일 크기에 비례하면 O(n), 제곱으로 증가하면 O(n²))");
