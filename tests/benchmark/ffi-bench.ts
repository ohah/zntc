#!/usr/bin/env bun
/**
 * ZTS FFI vs WASM vs CLI 벤치마크
 *
 * 세 가지 호출 방식의 트랜스파일 성능을 비교한다:
 *   - CLI: subprocess spawn (현재 방식)
 *   - WASM: WebAssembly in-process (별도 프로세스에서 실행)
 *   - FFI: 네이티브 dylib in-process (NAPI와 동일한 성능 특성)
 *
 * WASM과 FFI를 같은 프로세스에서 로드하면 심볼 충돌로 크래시하므로
 * 각 방식을 별도 프로세스로 실행한 뒤 결과를 취합한다.
 */

import { spawnSync } from "node:child_process";
import { resolve } from "node:path";
import { writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";

const ROOT = resolve(import.meta.dir, "../..");
const WARMUP = 3;
const ITERATIONS = 10;

// ─── Fixture 생성 ───

function generateTS(lines: number): string {
  const parts: string[] = [];
  for (let i = 0; i < lines; i++) {
    parts.push(`export const value${i}: number = ${i} * 2;`);
    if (i % 50 === 0) {
      parts.push(`export function compute${i}(x: number): number { return x * ${i}; }`);
    }
  }
  parts.push(`export default function main() { return value0; }`);
  return parts.join("\n");
}

// ─── 워커 스크립트 생성 ───

function createWorkerScript(method: "ffi" | "wasm" | "cli", sourceFile: string): string {
  const dir = mkdtempSync(resolve(tmpdir(), "zts-bench-worker-"));

  if (method === "ffi") {
    const script = `
import { dlopen, FFIType, ptr, toBuffer } from "bun:ffi";
import { readFileSync } from "node:fs";

const DYLIB = "${resolve(ROOT, "zig-out/lib/libzts.dylib")}";
const lib = dlopen(DYLIB, {
  zts_transpile: { args: [FFIType.ptr, FFIType.u32, FFIType.ptr, FFIType.u32, FFIType.u32, FFIType.u32, FFIType.ptr, FFIType.u32, FFIType.ptr, FFIType.u32, FFIType.ptr, FFIType.u32], returns: FFIType.ptr },
  zts_result_len: { args: [], returns: FFIType.u32 },
  zts_free_result: { args: [], returns: FFIType.void },
});

const source = readFileSync("${sourceFile}", "utf8");
const flags = (1 << 16) | (1 << 22);
const WARMUP = ${WARMUP};
const ITERATIONS = ${ITERATIONS};

function run() {
  const srcBuf = Buffer.from(source);
  const fileBuf = Buffer.from("input.ts");
  const rp = lib.symbols.zts_transpile(ptr(srcBuf), srcBuf.length, ptr(fileBuf), fileBuf.length, flags, 0, 0, 0, 0, 0, 0, 0);
  if (rp === null || rp === 0) throw new Error("FFI failed");
  lib.symbols.zts_free_result();
}

for (let i = 0; i < WARMUP; i++) run();
const times = [];
for (let i = 0; i < ITERATIONS; i++) {
  const start = Bun.nanoseconds();
  run();
  times.push((Bun.nanoseconds() - start) / 1000);
}
times.sort((a, b) => a - b);
console.log(JSON.stringify({
  medianUs: Math.round(times[Math.floor(times.length / 2)]),
  minUs: Math.round(times[0]),
  maxUs: Math.round(times[times.length - 1]),
}));
lib.close();
`;
    const path = resolve(dir, "worker.ts");
    writeFileSync(path, script);
    return path;
  }

  if (method === "wasm") {
    const script = `
import { readFileSync } from "node:fs";

const WASM_PATH = "${resolve(ROOT, "zig-out/bin/zts.wasm")}";
const encoder = new TextEncoder();
const decoder = new TextDecoder();

const wasmBytes = readFileSync(WASM_PATH);
let memory;
const imports = {
  wasi_snapshot_preview1: {
    fd_write(fd, iovs_ptr, iovs_len, nwritten_ptr) {
      new DataView(memory.buffer).setUint32(nwritten_ptr, 0, true);
      return 0;
    },
    fd_read: () => 8, fd_seek: () => 8, fd_pwrite: () => 8, fd_filestat_get: () => 8,
    random_get(buf_ptr, buf_len) {
      crypto.getRandomValues(new Uint8Array(memory.buffer, buf_ptr, buf_len));
      return 0;
    },
  },
};
const mod = new WebAssembly.Module(wasmBytes);
const instance = new WebAssembly.Instance(mod, imports);
memory = instance.exports.memory;
const w = instance.exports;

const source = readFileSync("${sourceFile}", "utf8");
const flags = (1 << 16) | (1 << 22);
const WARMUP = ${WARMUP};
const ITERATIONS = ${ITERATIONS};

function run() {
  const bytes = encoder.encode(source);
  const srcPtr = w.alloc(bytes.length);
  new Uint8Array(w.memory.buffer, srcPtr, bytes.length).set(bytes);
  const fileBytes = encoder.encode("input.ts");
  const filePtr = w.alloc(fileBytes.length);
  new Uint8Array(w.memory.buffer, filePtr, fileBytes.length).set(fileBytes);
  const packed = w.transpile(srcPtr, bytes.length, filePtr, fileBytes.length, flags, 0, 0, 0, 0, 0, 0, 0);
  w.dealloc(srcPtr, bytes.length);
  w.dealloc(filePtr, fileBytes.length);
  const outPtr = Number(packed >> 32n);
  const outLen = Number(packed & 0xffffffffn);
  if (outPtr === 0) throw new Error("WASM failed");
  w.dealloc(outPtr, outLen);
}

for (let i = 0; i < WARMUP; i++) run();
const times = [];
for (let i = 0; i < ITERATIONS; i++) {
  const start = Bun.nanoseconds();
  run();
  times.push((Bun.nanoseconds() - start) / 1000);
}
times.sort((a, b) => a - b);
console.log(JSON.stringify({
  medianUs: Math.round(times[Math.floor(times.length / 2)]),
  minUs: Math.round(times[0]),
  maxUs: Math.round(times[times.length - 1]),
}));
`;
    const path = resolve(dir, "worker.ts");
    writeFileSync(path, script);
    return path;
  }

  // CLI
  const script = `
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";

const ZTS_BIN = "${resolve(ROOT, "zig-out/bin/zts")}";
const source = readFileSync("${sourceFile}", "utf8");
const WARMUP = ${WARMUP};
const ITERATIONS = ${ITERATIONS};

function run() {
  spawnSync(ZTS_BIN, ["-"], { input: source, stdio: ["pipe", "pipe", "pipe"] });
}

for (let i = 0; i < WARMUP; i++) run();
const times = [];
for (let i = 0; i < ITERATIONS; i++) {
  const start = Bun.nanoseconds();
  run();
  times.push((Bun.nanoseconds() - start) / 1000);
}
times.sort((a, b) => a - b);
console.log(JSON.stringify({
  medianUs: Math.round(times[Math.floor(times.length / 2)]),
  minUs: Math.round(times[0]),
  maxUs: Math.round(times[times.length - 1]),
}));
`;
  const path = resolve(dir, "worker.ts");
  writeFileSync(path, script);
  return path;
}

// ─── 워커 실행 ───

interface BenchResult {
  method: string;
  scale: string;
  medianUs: number;
  minUs: number;
  maxUs: number;
}

function runWorker(method: "ffi" | "wasm" | "cli", scale: string, sourceFile: string): BenchResult {
  const label =
    method === "ffi" ? "FFI (NAPI-like)" : method === "wasm" ? "WASM" : "CLI (subprocess)";
  const workerPath = createWorkerScript(method, sourceFile);

  const result = spawnSync("bun", ["run", workerPath], {
    stdio: ["pipe", "pipe", "pipe"],
    timeout: 120000,
  });

  // 임시 파일 정리
  rmSync(resolve(workerPath, ".."), { recursive: true, force: true });

  if (result.status !== 0) {
    console.error(`  ${label}: FAILED`);
    if (result.stderr.length > 0)
      console.error(`  stderr: ${result.stderr.toString().slice(0, 200)}`);
    return { method: label, scale, medianUs: -1, minUs: -1, maxUs: -1 };
  }

  const stdout = result.stdout.toString().trim();
  try {
    const data = JSON.parse(stdout);
    return { method: label, scale, ...data };
  } catch {
    console.error(`  ${label}: parse error: ${stdout.slice(0, 200)}`);
    return { method: label, scale, medianUs: -1, minUs: -1, maxUs: -1 };
  }
}

// ─── Main ───

console.log("ZTS FFI vs WASM vs CLI Benchmark");
console.log(`  Warmup: ${WARMUP}, Iterations: ${ITERATIONS} (median)`);
console.log(`  Platform: ${process.platform} ${process.arch}`);
console.log(`  각 방식은 별도 프로세스에서 실행 (심볼 충돌 방지)\n`);

const scales = [
  { name: "small (100 lines)", lines: 100 },
  { name: "medium (1K lines)", lines: 1000 },
  { name: "large (5K lines)", lines: 5000 },
  { name: "xlarge (10K lines)", lines: 10000 },
];

const results: BenchResult[] = [];

for (const scale of scales) {
  const source = generateTS(scale.lines);
  const sizeKB = (Buffer.byteLength(source) / 1024).toFixed(0);

  // 소스 파일을 임시 파일에 저장
  const tmpDir = mkdtempSync(resolve(tmpdir(), "zts-bench-src-"));
  const sourceFile = resolve(tmpDir, "input.ts");
  writeFileSync(sourceFile, source);

  console.log(`--- ${scale.name} (${sizeKB} KB) ---`);

  for (const method of ["ffi", "wasm", "cli"] as const) {
    const label = method === "ffi" ? "FFI" : method === "wasm" ? "WASM" : "CLI";
    process.stdout.write(`  ${label}... `);
    const r = runWorker(method, scale.name, sourceFile);
    if (r.medianUs > 0) {
      console.log(`${r.medianUs} us (min: ${r.minUs}, max: ${r.maxUs})`);
    }
    results.push(r);
  }

  rmSync(tmpDir, { recursive: true, force: true });
}

// ─── 결과 출력 ───

console.log("\n===== Results =====\n");

for (const scale of scales) {
  const group = results
    .filter((r) => r.scale === scale.name)
    .sort((a, b) => {
      if (a.medianUs === -1) return 1;
      if (b.medianUs === -1) return -1;
      return a.medianUs - b.medianUs;
    });

  const fastest = group.find((r) => r.medianUs > 0)?.medianUs ?? 1;

  console.log(`### ${scale.name}`);
  console.log("| Method          | Median (us) | Min (us) | Max (us) | vs fastest |");
  console.log("|-----------------|-------------|----------|----------|------------|");
  for (const r of group) {
    const median = r.medianUs === -1 ? "FAIL" : String(r.medianUs);
    const min = r.minUs === -1 ? "-" : String(r.minUs);
    const max = r.maxUs === -1 ? "-" : String(r.maxUs);
    const ratio = r.medianUs > 0 ? `${(r.medianUs / fastest).toFixed(1)}x` : "-";
    console.log(
      `| ${r.method.padEnd(15)} | ${median.padStart(11)} | ${min.padStart(8)} | ${max.padStart(8)} | ${ratio.padStart(10)} |`,
    );
  }
  console.log();
}
