import { createRequire } from "module";
import { existsSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, resolve } from "path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const addonPath = resolve(__dirname, "../../zig-out/lib/bench-callback.node");

if (!existsSync(addonPath)) {
  console.error(`addon not found at ${addonPath}`);
  console.error(`run: zig build bench-callback`);
  process.exit(1);
}

const require = createRequire(import.meta.url);
const native = require(addonPath);

function noop() {
  return;
}

native.register(noop);

const sizes = [10_000, 100_000, 1_000_000];
const WARMUP = 10_000;

console.log("=== NAPI callback hot-path bench (#1891) ===\n");

console.log("Mode 1: napi_call_function (main thread, sync)");
const syncResults = {};
for (const N of sizes) {
  native.benchSync(WARMUP);
  const ms = native.benchSync(N);
  const nsPerCall = (ms * 1e6) / N;
  syncResults[N] = nsPerCall;
  console.log(
    `  ${N.toString().padStart(9)} iter: ${ms.toFixed(2).padStart(9)}ms  ${nsPerCall.toFixed(0).padStart(7)} ns/call`,
  );
}

console.log("\nMode 2: napi_call_threadsafe_function (worker → main, blocking)");
const tsfResults = {};
for (const N of sizes) {
  await native.benchTsf(WARMUP);
  const ms = await native.benchTsf(N);
  const nsPerCall = (ms * 1e6) / N;
  tsfResults[N] = nsPerCall;
  console.log(
    `  ${N.toString().padStart(9)} iter: ${ms.toFixed(2).padStart(9)}ms  ${nsPerCall.toFixed(0).padStart(7)} ns/call`,
  );
}

const ratio = tsfResults[1_000_000] / syncResults[1_000_000];
console.log(`\nTSF / Sync overhead ratio: ${ratio.toFixed(1)}x`);

console.log("\n=== 회귀 추정 (모듈당 평균 빌드 시간 가정) ===");
const tsfNs = tsfResults[1_000_000];
const overheadMs = tsfNs / 1e6;
console.log(
  `  TSF 호출 1회 비용: ${overheadMs.toFixed(4)}ms (${tsfNs.toFixed(0)} ns/call)\n`,
);
const scenarios = [
  { name: "트랜스파일 핫패스 (1ms)", buildMs: 1 },
  { name: "평균 모듈 (5ms)", buildMs: 5 },
  { name: "복잡 TSX (15ms)", buildMs: 15 },
];
for (const s of scenarios) {
  const pct = (overheadMs / s.buildMs) * 100;
  const verdict = pct < 5 ? "✅" : pct < 15 ? "⚠️" : "❌";
  console.log(
    `  ${s.name.padEnd(28)} → 회귀 ${pct.toFixed(1).padStart(5)}% ${verdict}`,
  );
}
