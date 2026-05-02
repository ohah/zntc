#!/usr/bin/env bun
/**
 * Flow Parse Benchmark — `parseFlowInterfaceDeclaration` body 보존 비용 측정.
 *
 * PR #2425 (issue #2422) 에서 Flow interface body 를 brace-skip → `parseObjectType`
 * 으로 회복. RN core 같은 Flow-heavy 코드베이스에서 cold parse 비용 영향 측정.
 *
 * Fixture: 다양한 interface 시그니처 (generic constraint, method, property, extends).
 * Reports median wall-clock time across N iterations.
 *
 * ## 측정 결과 (Apple M4, Debug build, median of 10 runs)
 *
 * | Scenario       | Bytes  | brace-skip | parseObjectType | Δ      |
 * |----------------|--------|-----------:|----------------:|-------:|
 * | 10 interfaces  | 5 KB   |   6.2 ms   |   5.3 ms        | -15%*  |
 * | 50 interfaces  | 25 KB  |   8.7 ms   |   9.3 ms        |  +7%   |
 * | 200 interfaces | 100 KB |  22.5 ms   |  25.6 ms        | +14%   |
 *
 * *10-interface 결과는 프로세스 spawn overhead (~5ms) 가 dominant 하므로 noise.
 * 실측 의미는 200-interface (큰 Flow 파일) 케이스 — parseObjectType 가 ~14% 더 느림.
 *
 * ## 결론
 *
 * RN bundle cold parse 시 Flow-heavy 파일 (RN core 의 hundreds of interfaces) 가 있어도
 * 절대값은 파일당 +50-100µs 수준. 전체 bundle 영향 미미 (~10ms below 1.5s baseline).
 * codegen schema_builder 가 interface body 를 직접 보는 이득 (#2415, #2348) 이 더 큼.
 *
 * 사용:
 *   bun run tests/benchmark/flow-parse.ts                     # 기본 fixture
 *   bun run tests/benchmark/flow-parse.ts --rn                # rn-example-app 실측
 */

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const ROOT = resolve(__dirname, "../..");
const ZTS_BIN = join(ROOT, "zig-out/bin/zts");
const ITERATIONS = 10;

function generateFlowInterfaces(count: number): string {
  const parts: string[] = ["// @flow", ""];
  for (let i = 0; i < count; i++) {
    parts.push(`type T${i} = $ReadOnly<{ id: string, value: number }>;`);
    parts.push(`export interface Emitter${i}<TMap: $ReadOnly<{[string]: $ReadOnlyArray<mixed>}>> {`);
    parts.push(`  addListener<E: $Keys<TMap>>(eventType: E, listener: (...args: TMap[E]) => mixed): void;`);
    parts.push(`  removeListener<E: $Keys<TMap>>(eventType: E): void;`);
    parts.push(`  emit<E: $Keys<TMap>>(eventType: E, ...args: TMap[E]): void;`);
    parts.push(`  +readOnly: T${i};`);
    parts.push(`  optional?: ?string;`);
    parts.push(`}`);
    parts.push(`export interface SubEmitter${i}<TMap: $ReadOnly<{[string]: $ReadOnlyArray<mixed>}>>`);
    parts.push(`  extends Emitter${i}<TMap> {`);
    parts.push(`  destroy(): void;`);
    parts.push(`}`);
    parts.push("");
  }
  return parts.join("\n");
}

function median(times: number[]): number {
  const sorted = [...times].sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length / 2)];
}

function measure(file: string): number {
  const times: number[] = [];
  // warmup
  spawnSync(ZTS_BIN, [file, "--platform=react-native"], { stdio: "pipe", timeout: 60000 });
  for (let i = 0; i < ITERATIONS; i++) {
    const start = performance.now();
    spawnSync(ZTS_BIN, [file, "--platform=react-native"], { stdio: "pipe", timeout: 60000 });
    times.push(performance.now() - start);
  }
  return median(times);
}

function bench(label: string, source: string, dir: string): { ms: number; bytes: number } {
  const file = join(dir, `${label}.js`);
  writeFileSync(file, source);
  const ms = measure(file);
  return { ms: Math.round(ms * 100) / 100, bytes: source.length };
}

function main() {
  const args = process.argv.slice(2);
  const useRn = args.includes("--rn");

  const dir = mkdtempSync(join(tmpdir(), "flow-parse-bench-"));
  try {
    console.log("\n=== Flow Parse Benchmark (median of " + ITERATIONS + " runs) ===\n");
    console.log("| Scenario              | Bytes  | ms    | µs/KB |");
    console.log("|-----------------------|--------|-------|-------|");

    const scenarios: Array<[string, string]> = [
      ["10 interfaces", generateFlowInterfaces(10)],
      ["50 interfaces", generateFlowInterfaces(50)],
      ["200 interfaces", generateFlowInterfaces(200)],
    ];

    for (const [label, source] of scenarios) {
      const { ms, bytes } = bench(label.replace(/\s/g, "-"), source, dir);
      const usPerKb = ((ms * 1000) / (bytes / 1024)).toFixed(1);
      console.log(`| ${label.padEnd(21)} | ${String(bytes).padStart(6)} | ${ms.toString().padStart(5)} | ${usPerKb.padStart(5)} |`);
    }

    if (useRn) {
      console.log("\n=== rn-example-app 실측 ===\n");
      const rnFiles = [
        "tests/integration/tests/fixtures/rn-example-app/node_modules/react-native/Libraries/vendor/emitter/EventEmitter.js",
        "tests/integration/tests/fixtures/rn-example-app/node_modules/react-native/src/private/webapis/performance/ResourceTiming.js",
      ];
      for (const rel of rnFiles) {
        const abs = join(ROOT, rel);
        const t = measure(abs);
        console.log(`  ${rel.split("/").pop()}: ${t.toFixed(2)} ms`);
      }
    }

    console.log("\nA/B 비교: `git stash` 로 parseObjectType → brace-skip revert 후");
    console.log("`zig build` 재빌드 + 본 스크립트 재실행. 결과 diff 비교.\n");
  } finally {
    rmSync(dir, { recursive: true });
  }
}

main();
