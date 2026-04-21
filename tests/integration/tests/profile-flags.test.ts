import { describe, test, expect, afterEach } from "bun:test";
import { runZts, createFixture } from "./helpers";
import { join } from "node:path";

// PR 2: profile infrastructure CLI/NAPI/env 진입점 통합 검증.
//
// 주의: 이 PR 에서는 hot-path timer 가 아직 삽입되지 않아 phase 가 실제로는
// 0 을 기록할 수 있다. 이 테스트는 "플래그 파싱 + 리포트 출력 메커니즘"이 정상
// 동작함을 검증한다. 실제 phase 수치 검증은 PR 3+ (Scanner/Parser timer)
// 삽입 후 별도 테스트가 담당.

describe("profile CLI flags", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test("--profile=all 는 성공 종료하고 리포트 헤더를 stderr 로 출력", async () => {
    const fixture = await createFixture({
      "index.ts": `const x: number = 1;\nexport const y = x + 2;`,
    });
    cleanup = fixture.cleanup;

    const result = await runZts([
      join(fixture.dir, "index.ts"),
      "--profile=all",
      "-o",
      join(fixture.dir, "out.js"),
    ]);

    expect(result.exitCode).toBe(0);
    // 기본 format=table → ZTS Profile 헤더가 표시되어야 함.
    expect(result.stderr).toContain("=== ZTS Profile ===");
  });

  test("--profile-format=json 은 유효한 JSON 블록을 출력", async () => {
    const fixture = await createFixture({
      "index.ts": `export const x = 1;`,
    });
    cleanup = fixture.cleanup;

    const result = await runZts([
      join(fixture.dir, "index.ts"),
      "--profile=all",
      "--profile-format=json",
      "-o",
      join(fixture.dir, "out.js"),
    ]);

    expect(result.exitCode).toBe(0);
    // JSON 블록 파싱 가능.
    const jsonStart = result.stderr.indexOf("{");
    expect(jsonStart).toBeGreaterThanOrEqual(0);
    const jsonText = result.stderr.slice(jsonStart);
    const parsed = JSON.parse(jsonText);
    expect(parsed.profile_version).toBe(1);
    expect(typeof parsed.total_ms).toBe("number");
    expect(parsed.level).toBe("summary");
    expect(parsed.phases).toBeDefined();
  });

  test("--profile-format=csv 는 헤더 행으로 시작", async () => {
    const fixture = await createFixture({
      "index.ts": `export const x = 1;`,
    });
    cleanup = fixture.cleanup;

    const result = await runZts([
      join(fixture.dir, "index.ts"),
      "--profile=all",
      "--profile-format=csv",
      "-o",
      join(fixture.dir, "out.js"),
    ]);

    expect(result.exitCode).toBe(0);
    expect(result.stderr).toContain("phase,total_ms,count,pct");
  });

  test("--profile-level=detailed 는 tree 포맷과 조합 가능", async () => {
    const fixture = await createFixture({
      "index.ts": `export const x = 1;`,
    });
    cleanup = fixture.cleanup;

    const result = await runZts([
      join(fixture.dir, "index.ts"),
      "--profile=all",
      "--profile-level=detailed",
      "--profile-format=tree",
      "-o",
      join(fixture.dir, "out.js"),
    ]);

    expect(result.exitCode).toBe(0);
    expect(result.stderr).toContain("=== ZTS Profile (detailed) ===");
  });

  test("--profile-level 가 잘못된 값이면 exit 1", async () => {
    const fixture = await createFixture({
      "index.ts": `export const x = 1;`,
    });
    cleanup = fixture.cleanup;

    const result = await runZts([
      join(fixture.dir, "index.ts"),
      "--profile=all",
      "--profile-level=bogus",
      "-o",
      join(fixture.dir, "out.js"),
    ]);

    expect(result.exitCode).not.toBe(0);
    expect(result.stderr).toContain("invalid --profile-level");
  });

  test("--profile-format 가 잘못된 값이면 exit 1", async () => {
    const fixture = await createFixture({
      "index.ts": `export const x = 1;`,
    });
    cleanup = fixture.cleanup;

    const result = await runZts([
      join(fixture.dir, "index.ts"),
      "--profile=all",
      "--profile-format=xml",
      "-o",
      join(fixture.dir, "out.js"),
    ]);

    expect(result.exitCode).not.toBe(0);
    expect(result.stderr).toContain("invalid --profile-format");
  });

  test("--profile 없으면 리포트 출력 없음 (breaking: 기존 --timing 기본 없음)", async () => {
    const fixture = await createFixture({
      "index.ts": `export const x = 1;`,
    });
    cleanup = fixture.cleanup;

    const result = await runZts([join(fixture.dir, "index.ts"), "-o", join(fixture.dir, "out.js")]);

    expect(result.exitCode).toBe(0);
    expect(result.stderr).not.toContain("ZTS Profile");
  });

  test("ZTS_PROFILE env 로 활성화 가능", async () => {
    const fixture = await createFixture({
      "index.ts": `export const x = 1;`,
    });
    cleanup = fixture.cleanup;

    const result = await runZts(
      [
        join(fixture.dir, "index.ts"),
        "-o",
        join(fixture.dir, "out.js"),
        "--profile-format=json", // 활성 여부는 env 로, 포맷만 CLI 로.
      ],
      { env: { ...process.env, ZTS_PROFILE: "all" } },
    );

    expect(result.exitCode).toBe(0);
    const jsonStart = result.stderr.indexOf("{");
    expect(jsonStart).toBeGreaterThanOrEqual(0);
    const parsed = JSON.parse(result.stderr.slice(jsonStart));
    expect(parsed.profile_version).toBe(1);
  });

  test("--timing 플래그는 제거됨 (breaking)", async () => {
    const fixture = await createFixture({
      "index.ts": `export const x = 1;`,
    });
    cleanup = fixture.cleanup;

    const result = await runZts([
      join(fixture.dir, "index.ts"),
      "--timing",
      "-o",
      join(fixture.dir, "out.js"),
    ]);

    // --timing 은 이제 unknown argument — exit 1 또는 경고. 최소한 Timing for ... 출력은 없어야.
    expect(result.stderr).not.toContain("Timing for");
  });

  test("--help 에 --profile 섹션 포함", async () => {
    const result = await runZts(["--help"]);
    expect(result.stdout).toContain("--profile=");
    expect(result.stdout).toContain("--profile-level=");
    expect(result.stdout).toContain("--profile-format=");
    expect(result.stdout).toContain("ZTS_PROFILE");
  });

  // ─── Phase 실제 수치 기록 검증 (PR 3+ 에서 hot-path timer 가 삽입됨) ───

  test("--profile=parse 는 parse phase 에 실제 수치 기록", async () => {
    const fixture = await createFixture({
      "index.ts": `
        export const x: number = 1;
        export function foo(a: string, b: number) {
          return a + b.toString();
        }
        export class K {
          constructor(public name: string) {}
          greet() { return "Hi " + this.name; }
        }
      `,
    });
    cleanup = fixture.cleanup;

    const result = await runZts([
      join(fixture.dir, "index.ts"),
      "--profile=parse",
      "--profile-format=json",
      "-o",
      join(fixture.dir, "out.js"),
    ]);

    expect(result.exitCode).toBe(0);
    const parsed = JSON.parse(result.stderr.slice(result.stderr.indexOf("{")));
    expect(parsed.phases.parse).toBeDefined();
    expect(parsed.phases.parse.total_ms).toBeGreaterThan(0);
    expect(parsed.phases.parse.count).toBeGreaterThanOrEqual(1);
  });
});
