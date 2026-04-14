#!/usr/bin/env bun
/**
 * Tree-shake size benchmark — ZTS vs esbuild / rolldown / rspack.
 *
 * 동일 입력에 대해 각 번들러의 최종 출력 크기를 raw / gzip 기준으로 비교.
 * 각 fixture는 "전체 크기" 대비 "사용된 export만" 크기가 얼마나 줄어드는지를 측정.
 *
 * 실행: bun run tree-shake-size.ts
 */

import { spawnSync } from "node:child_process";
import {
  mkdtempSync,
  writeFileSync,
  rmSync,
  mkdirSync,
  existsSync,
  readFileSync,
  readdirSync,
  statSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { gzipSync } from "node:zlib";

const ROOT = resolve(__dirname, "../..");
const ZTS_BIN = join(ROOT, "zig-out/bin/zts");
const BENCH_BIN = join(__dirname, "node_modules/.bin");

function findBin(name: string): string | null {
  const p = join(BENCH_BIN, name);
  return existsSync(p) ? p : null;
}

// ============================================================
// Fixtures
// ============================================================

type Fixture = {
  name: string;
  description: string;
  build(dir: string): string;
  liveMarkers: string[]; // 출력에 있어야 함
  deadMarkers: string[]; // 출력에 없어야 함 (올바른 tree-shake 시)
};

const fixtures: Fixture[] = [
  {
    name: "synthetic-10",
    description: "lib.ts의 10개 export 중 1개만 import",
    build(dir) {
      const parts: string[] = [];
      for (let i = 0; i < 10; i++) {
        parts.push(
          `export function fn${i}() { return "PAYLOAD_${i}_" + ${"x".repeat(40)}.length; }`,
        );
      }
      writeFileSync(join(dir, "lib.ts"), parts.join("\n"));
      writeFileSync(join(dir, "entry.ts"), `import { fn5 } from './lib';\nconsole.log(fn5());\n`);
      writeFileSync(
        join(dir, "package.json"),
        JSON.stringify({ name: "fx", type: "module", sideEffects: false }),
      );
      return join(dir, "entry.ts");
    },
    liveMarkers: ["PAYLOAD_5"],
    deadMarkers: Array.from({ length: 10 }, (_, i) => `PAYLOAD_${i}`).filter(
      (m) => m !== "PAYLOAD_5",
    ),
  },
  {
    name: "barrel-chain",
    description: "barrel → a/b/c (총 6 export) 중 1개만 used",
    build(dir) {
      writeFileSync(
        join(dir, "entry.ts"),
        `import { used_a } from './barrel';\nconsole.log(used_a());\n`,
      );
      writeFileSync(
        join(dir, "barrel.ts"),
        `export { used_a, unused_a } from './a';\nexport { used_b, unused_b } from './b';\nexport { used_c, unused_c } from './c';\n`,
      );
      for (const letter of ["a", "b", "c"]) {
        writeFileSync(
          join(dir, `${letter}.ts`),
          `export function used_${letter}() { return "USED_${letter.toUpperCase()}_${"x".repeat(80)}"; }\nexport function unused_${letter}() { return "UNUSED_${letter.toUpperCase()}_${"x".repeat(80)}"; }\n`,
        );
      }
      writeFileSync(
        join(dir, "package.json"),
        JSON.stringify({ name: "fx", type: "module", sideEffects: false }),
      );
      return join(dir, "entry.ts");
    },
    liveMarkers: ["USED_A_"],
    deadMarkers: ["UNUSED_A_", "USED_B_", "UNUSED_B_", "USED_C_", "UNUSED_C_"],
  },
  {
    name: "utils-partial",
    description: "20개 유틸 중 2개만 사용 (lodash 유사 패턴)",
    build(dir) {
      const parts: string[] = [];
      for (let i = 0; i < 20; i++) {
        parts.push(
          `export function util${i}(x: number): number { return x + ${i} + "${"pad".repeat(20)}".length; }`,
        );
      }
      writeFileSync(join(dir, "utils.ts"), parts.join("\n"));
      writeFileSync(
        join(dir, "entry.ts"),
        `import { util3, util17 } from './utils';\nconsole.log(util3(1) + util17(2));\n`,
      );
      writeFileSync(
        join(dir, "package.json"),
        JSON.stringify({ name: "fx", type: "module", sideEffects: false }),
      );
      return join(dir, "entry.ts");
    },
    liveMarkers: ["util3", "util17"],
    deadMarkers: ["util0 ", "util1 ", "util19 "].filter((m) => !["util3 ", "util17 "].includes(m)),
  },
];

// ============================================================
// Bundler runners — 각자 fixture dir + entry를 받아 output 경로 반환
// ============================================================

type Runner = { name: string; run(dir: string, entry: string): string | null };

const runners: Runner[] = [
  {
    name: "ZTS",
    run(dir, entry) {
      const out = join(dir, "zts.js");
      const r = spawnSync(ZTS_BIN, ["--bundle", entry, "--minify", "-o", out], {
        encoding: "utf8",
      });
      if (r.status !== 0) return null;
      return out;
    },
  },
  {
    name: "esbuild",
    run(dir, entry) {
      const bin = findBin("esbuild");
      if (!bin) return null;
      const out = join(dir, "esbuild.js");
      const r = spawnSync(
        bin,
        [entry, "--bundle", "--minify", "--loader:.ts=ts", "--format=iife", `--outfile=${out}`],
        { encoding: "utf8" },
      );
      if (r.status !== 0) return null;
      return out;
    },
  },
  {
    name: "rolldown",
    run(dir, entry) {
      const bin = findBin("rolldown");
      if (!bin) return null;
      const outDir = join(dir, "rolldown-out");
      mkdirSync(outDir, { recursive: true });
      const r = spawnSync(bin, [entry, "--dir", outDir, "--minify"], { encoding: "utf8" });
      if (r.status !== 0) return null;
      // rolldown은 dir에 파일을 쏟아냄 — 가장 큰 파일을 entry로 가정
      const files = readdirSync(outDir).filter((f) => f.endsWith(".js") || f.endsWith(".mjs"));
      if (files.length === 0) return null;
      const totalPath = files
        .map((f) => ({ f, size: statSync(join(outDir, f)).size }))
        .sort((a, b) => b.size - a.size)[0].f;
      return join(outDir, totalPath);
    },
  },
  {
    name: "rspack",
    run(dir, entry) {
      const bin = findBin("rspack");
      if (!bin) return null;
      const outDir = join(dir, "rspack-out");
      mkdirSync(outDir, { recursive: true });
      const config = join(dir, "rspack.config.js");
      writeFileSync(
        config,
        `module.exports = {
  mode: 'production',
  entry: ${JSON.stringify(entry)},
  output: { path: ${JSON.stringify(outDir)}, filename: 'rspack.js' },
  resolve: { extensions: ['.ts', '.js'] },
  module: { rules: [{ test: /\\.ts$/, type: 'javascript/auto', use: { loader: 'builtin:swc-loader', options: { jsc: { parser: { syntax: 'typescript' } } } } }] },
};`,
      );
      const r = spawnSync(bin, ["build", "--config", config], { cwd: dir, encoding: "utf8" });
      if (r.status !== 0) return null;
      return join(outDir, "rspack.js");
    },
  },
];

// ============================================================
// Runner
// ============================================================

type Row = { bundler: string; raw: number; gzip: number; ok: boolean };

function measure(path: string, fixture: Fixture): { raw: number; gzip: number; ok: boolean } {
  const buf = readFileSync(path);
  const src = buf.toString("utf8");
  const liveOk = fixture.liveMarkers.every((m) => src.includes(m));
  const deadOk = fixture.deadMarkers.every((m) => !src.includes(m));
  return { raw: buf.length, gzip: gzipSync(buf).length, ok: liveOk && deadOk };
}

function pct(part: number, whole: number): string {
  if (whole === 0) return "-";
  return ((100 * part) / whole).toFixed(1) + "%";
}

function runFixture(fx: Fixture): Row[] {
  const dir = mkdtempSync(join(tmpdir(), `zts-ts-${fx.name}-`));
  try {
    const entry = fx.build(dir);
    const rows: Row[] = [];
    for (const r of runners) {
      const out = r.run(dir, entry);
      if (!out || !existsSync(out)) {
        rows.push({ bundler: r.name, raw: 0, gzip: 0, ok: false });
        continue;
      }
      const m = measure(out, fx);
      rows.push({ bundler: r.name, ...m });
    }
    return rows;
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function printTable(fx: Fixture, rows: Row[]) {
  console.log(`\n### ${fx.name} — ${fx.description}\n`);
  console.log("| Bundler | Raw | Gzip | Correct | vs ZTS (raw) |");
  console.log("|---|---:|---:|:---:|---:|");
  const zts = rows.find((r) => r.bundler === "ZTS");
  for (const r of rows) {
    const raw = r.raw ? `${r.raw} B` : "—";
    const gzip = r.gzip ? `${r.gzip} B` : "—";
    const ok = r.ok ? "✓" : "✗";
    const rel = zts && zts.raw && r.raw ? pct(r.raw, zts.raw) : "-";
    console.log(`| ${r.bundler} | ${raw} | ${gzip} | ${ok} | ${rel} |`);
  }
}

function main() {
  if (!existsSync(ZTS_BIN)) {
    console.error(`ZTS binary not found: ${ZTS_BIN}\nrun: zig build`);
    process.exit(1);
  }
  console.log("# Tree-shake size benchmark\n");
  console.log(
    `Correct = 모든 live marker 포함 + dead marker 제외.\nvs ZTS (raw) = 해당 번들러 크기 / ZTS 크기.\n`,
  );
  for (const fx of fixtures) {
    const rows = runFixture(fx);
    printTable(fx, rows);
  }
}

main();
