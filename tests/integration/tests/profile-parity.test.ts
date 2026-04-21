import { describe, test, expect, afterEach, beforeAll, afterAll } from "bun:test";
import { join } from "node:path";
import { createFixture, runZts } from "./helpers";
import { init, close, benchmark } from "../../../packages/core/index";

// PR 11: CLI ↔ NAPI feature parity 검증.
//
// 같은 입력 + 옵션 → 같은 JSON 출력 구조. 사용자가 CLI 스크립트와 NAPI
// 사용 코드를 오가며 동일한 키/형식으로 기대할 수 있음을 보장.

describe("CLI ↔ NAPI profile/benchmark parity", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  const source = `
    export const x: number = 1;
    export function foo(a: string) { return a + "!"; }
  `;

  describe("benchmark JSON schema", () => {
    beforeAll(() => init());
    afterAll(() => close());

    test("CLI 와 NAPI 가 같은 phase key 구조", async () => {
      const fixture = await createFixture({ "input.ts": source });
      cleanup = fixture.cleanup;

      const cliResult = await runZts([
        "bench",
        "--phase=parse",
        "--iterations=5",
        "--warmup=1",
        "--format=json",
        join(fixture.dir, "input.ts"),
      ]);
      expect(cliResult.exitCode).toBe(0);
      const cliJson = JSON.parse(cliResult.stdout);

      const napiResult = benchmark({
        source,
        filename: "input.ts",
        phases: ["parse"],
        iterations: 5,
        warmup: 1,
      });

      // Phase 키셋 동일.
      expect(Object.keys(cliJson.phases).sort()).toEqual(Object.keys(napiResult.phases).sort());

      // 각 phase stats 키셋 동일.
      const cliStatKeys = Object.keys(cliJson.phases.parse).sort();
      const napiStatKeys = Object.keys(napiResult.phases.parse).sort();
      expect(cliStatKeys).toEqual(napiStatKeys);

      // 공통 키 7개: samples, mean_ms, median_ms, p95_ms, p99_ms, min_ms, max_ms, stddev_ms
      for (const k of [
        "samples",
        "mean_ms",
        "median_ms",
        "p95_ms",
        "p99_ms",
        "min_ms",
        "max_ms",
        "stddev_ms",
      ]) {
        expect(cliStatKeys).toContain(k);
        expect(napiStatKeys).toContain(k);
      }
    });

    test("여러 phase 동시 — 키 누락 없음", async () => {
      const fixture = await createFixture({ "input.ts": source });
      cleanup = fixture.cleanup;

      const cliResult = await runZts([
        "bench",
        "--phase=parse,transform,codegen",
        "--iterations=3",
        "--warmup=1",
        "--format=json",
        join(fixture.dir, "input.ts"),
      ]);
      expect(cliResult.exitCode).toBe(0);
      const cliJson = JSON.parse(cliResult.stdout);

      const napiResult = benchmark({
        source,
        filename: "input.ts",
        phases: ["parse", "transform", "codegen"],
        iterations: 3,
        warmup: 1,
      });

      expect(Object.keys(cliJson.phases).sort()).toEqual(Object.keys(napiResult.phases).sort());
    });
  });

  describe("profile JSON schema (CLI only — NAPI 는 build result 에 통합 예정)", () => {
    test("CLI `--profile-format=json` 은 profile_version=1 + phases 객체", async () => {
      const fixture = await createFixture({ "input.ts": source });
      cleanup = fixture.cleanup;

      const result = await runZts([
        join(fixture.dir, "input.ts"),
        "--profile=all",
        "--profile-format=json",
        "-o",
        join(fixture.dir, "out.js"),
      ]);

      expect(result.exitCode).toBe(0);
      const parsed = JSON.parse(result.stderr.slice(result.stderr.indexOf("{")));
      expect(parsed.profile_version).toBe(1);
      expect(typeof parsed.total_ms).toBe("number");
      expect(["summary", "detailed", "per-module", "per-pass"]).toContain(parsed.level);
      expect(typeof parsed.phases).toBe("object");

      // 각 phase 는 { total_ms, count, pct } schema
      for (const [name, stats] of Object.entries(parsed.phases) as Array<[string, any]>) {
        expect(typeof name).toBe("string");
        expect(typeof stats.total_ms).toBe("number");
        expect(typeof stats.count).toBe("number");
        expect(typeof stats.pct).toBe("number");
      }
    });
  });
});

describe("feature parity — 모든 옵션 CLI ↔ NAPI 양쪽 노출", () => {
  test("profile / profileLevel / profileFormat / stopAfter 모두 NAPI 에 존재", async () => {
    // TS type level check — import 만 해도 타입 검증됨.
    const { transpile } = await import("../../../packages/core/index");
    // 실행은 skip (type check 용) — 실제 동작은 다른 테스트가 검증.
    const shape: Parameters<typeof transpile>[1] = {
      profile: ["parse"],
      profileLevel: "summary",
      profileFormat: "json",
      stopAfter: "parse",
    };
    expect(shape).toBeDefined();
  });

  test("benchmark NAPI 가 CLI 와 동일한 옵션 지원", async () => {
    const { benchmark } = await import("../../../packages/core/index");
    // options 객체 key 검증.
    const opts: Parameters<typeof benchmark>[0] = {
      source: "x",
      filename: "input.ts",
      phases: ["parse"],
      iterations: 10,
      warmup: 2,
    };
    expect(opts.phases).toHaveLength(1);
  });
});
