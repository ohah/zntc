import { describe, test, expect, afterEach, beforeAll, afterAll } from "bun:test";
import { existsSync, readFileSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { createFixture, runZts } from "./helpers";
import { init, close, benchmark } from "../../../packages/core/index";

// PR 5: zts bench 서브커맨드 + NAPI benchmark() API.
//
// CLI 와 NAPI 동일 기능:
//   - 특정 phase 를 N 회 반복 실행
//   - mean/median/p95/p99/stddev/min/max 통계
//   - save/compare (CLI 만, NAPI 는 결과 객체 직접 조작 가능)

const smallSource = `
  export const x: number = 1;
  export function foo(a: string, b: number) { return a + b.toString(); }
  export class K { constructor(public name: string) {} }
`;

describe("zts bench subcommand (CLI)", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test("--phase=parse 로 bench 실행 + 테이블 출력", async () => {
    const fixture = await createFixture({ "input.ts": smallSource });
    cleanup = fixture.cleanup;

    const result = await runZts([
      "bench",
      "--phase=parse",
      "--iterations=10",
      "--warmup=2",
      join(fixture.dir, "input.ts"),
    ]);

    expect(result.exitCode).toBe(0);
    expect(result.stdout).toContain("=== ZTS Benchmark ===");
    expect(result.stdout).toContain("parse");
    expect(result.stdout).toContain("ms");
  });

  test("--format=json 은 유효한 JSON 출력", async () => {
    const fixture = await createFixture({ "input.ts": smallSource });
    cleanup = fixture.cleanup;

    const result = await runZts([
      "bench",
      "--phase=parse",
      "--iterations=10",
      "--warmup=2",
      "--format=json",
      join(fixture.dir, "input.ts"),
    ]);

    expect(result.exitCode).toBe(0);
    const json = JSON.parse(result.stdout);
    expect(json.bench_version).toBe(1);
    expect(json.iterations).toBe(10);
    expect(json.warmup).toBe(2);
    expect(json.phases.parse).toBeDefined();
    expect(json.phases.parse.samples).toBe(10);
    expect(typeof json.phases.parse.mean_ms).toBe("number");
    expect(typeof json.phases.parse.median_ms).toBe("number");
    expect(typeof json.phases.parse.p95_ms).toBe("number");
    expect(typeof json.phases.parse.p99_ms).toBe("number");
    expect(typeof json.phases.parse.stddev_ms).toBe("number");
  });

  test("--format=csv 는 헤더 + 데이터 행", async () => {
    const fixture = await createFixture({ "input.ts": smallSource });
    cleanup = fixture.cleanup;

    const result = await runZts([
      "bench",
      "--phase=parse",
      "--iterations=5",
      "--warmup=1",
      "--format=csv",
      join(fixture.dir, "input.ts"),
    ]);

    expect(result.exitCode).toBe(0);
    expect(result.stdout).toContain(
      "phase,samples,mean_ms,median_ms,p95_ms,p99_ms,min_ms,max_ms,stddev_ms",
    );
    expect(result.stdout).toContain("parse,");
  });

  test("--save --compare 워크플로우", async () => {
    const fixture = await createFixture({ "input.ts": smallSource });
    cleanup = fixture.cleanup;
    const baselinePath = join(tmpdir(), `zts-bench-${Date.now()}.json`);

    // 1. 저장
    const save = await runZts([
      "bench",
      "--phase=parse",
      "--iterations=5",
      "--warmup=1",
      "--save=" + baselinePath,
      join(fixture.dir, "input.ts"),
    ]);
    expect(save.exitCode).toBe(0);
    expect(existsSync(baselinePath)).toBe(true);
    const baseline = JSON.parse(readFileSync(baselinePath, "utf-8"));
    expect(baseline.bench_version).toBe(1);
    expect(baseline.phases.parse).toBeDefined();

    // 2. 비교
    const cmp = await runZts([
      "bench",
      "--phase=parse",
      "--iterations=5",
      "--warmup=1",
      "--compare=" + baselinePath,
      join(fixture.dir, "input.ts"),
    ]);
    expect(cmp.exitCode).toBe(0);
    expect(cmp.stdout).toContain("vs baseline");
    expect(cmp.stdout).toMatch(/improved|regressed|unchanged/);

    unlinkSync(baselinePath);
  });

  test("여러 phase CSV 입력", async () => {
    const fixture = await createFixture({ "input.ts": smallSource });
    cleanup = fixture.cleanup;

    const result = await runZts([
      "bench",
      "--phase=parse,transform",
      "--iterations=5",
      "--warmup=1",
      "--format=json",
      join(fixture.dir, "input.ts"),
    ]);

    // transform timer 는 PR 7 에서 삽입되므로 수치는 0. 구조 검증만.
    expect(result.exitCode).toBe(0);
    const json = JSON.parse(result.stdout);
    expect(json.phases.parse).toBeDefined();
    expect(json.phases.transform).toBeDefined();
  });

  test("phase 없으면 exit 1", async () => {
    const fixture = await createFixture({ "input.ts": smallSource });
    cleanup = fixture.cleanup;

    const result = await runZts(["bench", join(fixture.dir, "input.ts")]);
    expect(result.exitCode).not.toBe(0);
    expect(result.stderr).toContain("--phase=");
  });

  test("input file 없으면 exit 1", async () => {
    const result = await runZts(["bench", "--phase=parse"]);
    expect(result.exitCode).not.toBe(0);
    expect(result.stderr).toContain("missing input file");
  });

  test("알 수 없는 phase 이름은 exit 1", async () => {
    const fixture = await createFixture({ "input.ts": smallSource });
    cleanup = fixture.cleanup;

    const result = await runZts(["bench", "--phase=bogus_phase", join(fixture.dir, "input.ts")]);
    expect(result.exitCode).not.toBe(0);
    expect(result.stderr).toContain("unknown phase");
  });

  test("--phase=all 은 거부 (구체적 phase 이름 필요)", async () => {
    const fixture = await createFixture({ "input.ts": smallSource });
    cleanup = fixture.cleanup;

    const result = await runZts(["bench", "--phase=all", join(fixture.dir, "input.ts")]);
    expect(result.exitCode).not.toBe(0);
    expect(result.stderr).toContain("not allowed");
  });

  test("--help 에 zts bench 섹션 포함", async () => {
    const result = await runZts(["--help"]);
    expect(result.stdout).toContain("zts bench");
    expect(result.stdout).toContain("--phase=");
    expect(result.stdout).toContain("--iterations=");
    expect(result.stdout).toContain("--save=");
    expect(result.stdout).toContain("--compare=");
  });
});

describe("benchmark() NAPI API", () => {
  beforeAll(() => init());
  afterAll(() => close());

  test("source + phases 로 benchmark 호출", () => {
    const result = benchmark({
      source: smallSource,
      filename: "input.ts",
      phases: ["parse"],
      iterations: 10,
      warmup: 2,
    });
    expect(result.phases.parse).toBeDefined();
    expect(result.phases.parse.samples).toBe(10);
    expect(typeof result.phases.parse.mean_ms).toBe("number");
    expect(typeof result.phases.parse.median_ms).toBe("number");
    expect(typeof result.phases.parse.p95_ms).toBe("number");
    expect(typeof result.phases.parse.stddev_ms).toBe("number");
  });

  test("여러 phase 동시 측정", () => {
    const result = benchmark({
      source: smallSource,
      filename: "input.ts",
      phases: ["parse", "transform"],
      iterations: 5,
      warmup: 1,
    });
    expect(result.phases.parse).toBeDefined();
    expect(result.phases.transform).toBeDefined();
  });

  test("default iterations=100, warmup=10", () => {
    const result = benchmark({
      source: smallSource,
      filename: "input.ts",
      phases: ["parse"],
    });
    expect(result.phases.parse.samples).toBe(100);
  });

  test("phases 비어있으면 throw", () => {
    expect(() =>
      benchmark({
        source: smallSource,
        phases: [],
      }),
    ).toThrow(/non-empty/);
  });

  test("source/file 둘 다 없으면 throw", () => {
    expect(() =>
      benchmark({
        phases: ["parse"],
      } as any),
    ).toThrow(/source.*file/);
  });

  test("CLI json 출력 ↔ NAPI result parity", () => {
    const napi = benchmark({
      source: smallSource,
      filename: "input.ts",
      phases: ["parse"],
      iterations: 5,
      warmup: 1,
    });
    // NAPI 결과가 CLI JSON 과 동일한 키셋
    const stats = napi.phases.parse;
    expect(stats).toHaveProperty("samples");
    expect(stats).toHaveProperty("mean_ms");
    expect(stats).toHaveProperty("median_ms");
    expect(stats).toHaveProperty("p95_ms");
    expect(stats).toHaveProperty("p99_ms");
    expect(stats).toHaveProperty("min_ms");
    expect(stats).toHaveProperty("max_ms");
    expect(stats).toHaveProperty("stddev_ms");
  });
});
