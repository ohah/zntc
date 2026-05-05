/**
 * Benchmark runner 들이 공유하는 zts 바이너리 호출/git/CLI 파싱 헬퍼.
 *
 * 동일한 buildBin/getCommit/parsePositiveInt/parseProfileJson 가
 * bundle-perf / monorepo-perf / const-prepass 에 중복돼 있어 통합.
 */

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join, resolve } from "node:path";

export const ROOT = resolve(__dirname, "../..");
export const ZTS_BIN = join(ROOT, "zig-out/bin/zts");

export function buildBin(label: string): void {
  if (existsSync(ZTS_BIN)) return;
  console.log(`[${label}] zts binary not found, building ReleaseFast...`);
  const r = spawnSync("zig", ["build", "-Doptimize=ReleaseFast"], {
    cwd: ROOT,
    stdio: "inherit",
  });
  if (r.status !== 0) throw new Error("zig build failed");
}

/// `tests/benchmark/node_modules/.bin/<name>` → `<root>/node_modules/.bin/<name>` fallback.
/// 비교 대상 (rolldown / rspack / esbuild) 가 어느 쪽에 설치돼 있어도 동작하도록.
export function findNodeModulesBin(name: string): string | null {
  const local = join(__dirname, "node_modules", ".bin", name);
  if (existsSync(local)) return local;
  const root = join(ROOT, "node_modules", ".bin", name);
  if (existsSync(root)) return root;
  return null;
}

export function getCommit(): string {
  const r = spawnSync("git", ["rev-parse", "--short", "HEAD"], {
    cwd: ROOT,
    stdio: "pipe",
  });
  return r.stdout.toString().trim() || "unknown";
}

export function parsePositiveInt(name: string, raw: string | undefined): number {
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 1) throw new Error(`${name} must be a positive integer`);
  return n;
}

export interface ProfilePhase {
  total_ms: number;
  count: number;
  pct: number;
  self_ms?: number;
  self_pct?: number;
}

export interface ProfileJson {
  profile_version: number;
  total_ms: number;
  level: string;
  phases: Record<string, ProfilePhase | undefined>;
}

/// stdout/stderr 에 섞여 나온 `--profile-format=json` 블록을 추출해 파싱.
export function parseProfileJson(output: string): ProfileJson {
  const marker = '"profile_version"';
  const markerIndex = output.indexOf(marker);
  if (markerIndex < 0) {
    throw new Error(`missing profile JSON output: ${output.slice(0, 800)}`);
  }

  const start = output.lastIndexOf("{", markerIndex);
  if (start < 0) {
    throw new Error(`malformed profile JSON output: ${output.slice(0, 800)}`);
  }

  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let i = start; i < output.length; i++) {
    const ch = output[i];

    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch === "\\") {
        escaped = true;
      } else if (ch === '"') {
        inString = false;
      }
      continue;
    }

    if (ch === '"') {
      inString = true;
      continue;
    }
    if (ch === "{") {
      depth++;
      continue;
    }
    if (ch === "}") {
      depth--;
      if (depth === 0) {
        return JSON.parse(output.slice(start, i + 1)) as ProfileJson;
      }
    }
  }

  throw new Error(`unterminated profile JSON output: ${output.slice(start, start + 800)}`);
}
