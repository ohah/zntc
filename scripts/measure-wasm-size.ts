#!/usr/bin/env bun
/**
 * #1899 — WASM bundle size 측정 + 분리 빌드 결과 보고.
 *
 * `zig-out/bin/zts.wasm` (transpile-only) 와 `zts-bundler.wasm` (bundler) 의
 * raw / gzip / brotli 사이즈를 측정해서 마크다운 표로 출력. CI 또는 로컬에서
 * 사이즈 회귀 추적용.
 *
 * 사용법:
 *   zig build wasm wasm-bundler -Doptimize=ReleaseSmall
 *   bun scripts/measure-wasm-size.ts
 */

import { readFileSync, statSync, existsSync } from "node:fs";
import { gzipSync, brotliCompressSync, constants as zlibConst } from "node:zlib";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");

const targets = [
  { name: "zts.wasm", role: "transpile-only", path: "zig-out/bin/zts.wasm" },
  { name: "zts-bundler.wasm", role: "bundler", path: "zig-out/bin/zts-bundler.wasm" },
];

const fmt = (bytes: number): string => {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KiB`;
  return `${(bytes / 1024 / 1024).toFixed(2)} MiB`;
};

let missingAny = false;
const rows = targets.map((t) => {
  const abs = join(repoRoot, t.path);
  if (!existsSync(abs)) {
    missingAny = true;
    return { ...t, raw: 0, gzip: 0, brotli: 0, missing: true };
  }
  const buf = readFileSync(abs);
  const raw = statSync(abs).size;
  const gzip = gzipSync(buf, { level: 9 }).length;
  const brotli = brotliCompressSync(buf, {
    params: { [zlibConst.BROTLI_PARAM_QUALITY]: 11 },
  }).length;
  return { ...t, raw, gzip, brotli, missing: false };
});

console.log("| Target | Role | Raw | Gzip (-9) | Brotli (q=11) |");
console.log("|---|---|---:|---:|---:|");
for (const r of rows) {
  if (r.missing) {
    console.log(`| \`${r.name}\` | ${r.role} | _missing — run \`zig build wasm wasm-bundler\`_ | | |`);
    continue;
  }
  console.log(`| \`${r.name}\` | ${r.role} | ${fmt(r.raw)} | ${fmt(r.gzip)} | ${fmt(r.brotli)} |`);
}

if (missingAny) {
  console.error("\n[error] one or more wasm artifacts missing — build with `zig build wasm wasm-bundler`");
  process.exit(1);
}
