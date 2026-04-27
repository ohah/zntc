import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const ROOT = resolve(__dirname, "../..");

function runBun(args: string[]) {
  return spawnSync("bun", args, {
    cwd: ROOT,
    stdio: "pipe",
    timeout: 180000,
  });
}

describe("benchmark smoke diagnostics", () => {
  test("--keep-output preserves bundler outputs under the requested directory", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-smoke-keep-"));
    try {
      const r = runBun([
        "run",
        "tests/benchmark/smoke.ts",
        "--filter=safe-buffer",
        `--keep-output=${dir}`,
      ]);

      expect(r.status, r.stderr?.toString()).toBe(0);
      const projectDir = join(dir, "safe-buffer");
      expect(existsSync(join(projectDir, "dist-zts.js"))).toBe(true);
      expect(existsSync(join(projectDir, "dist-esbuild.js"))).toBe(true);
      expect(readdirSync(projectDir).some((name) => name.includes("rolldown"))).toBe(true);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("--json writes build args, output paths, sizes, output match, and stderr summaries", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-smoke-json-"));
    const jsonPath = join(dir, "report.json");
    try {
      const r = runBun([
        "run",
        "tests/benchmark/smoke.ts",
        "--filter=cookie",
        `--json=${jsonPath}`,
      ]);

      expect(r.status, r.stderr?.toString()).toBe(0);
      const report = JSON.parse(readFileSync(jsonPath, "utf-8"));
      expect(report.results).toHaveLength(1);
      const cookie = report.results[0];
      expect(cookie.project).toBe("cookie");
      expect(typeof cookie.outputMatch).toBe("boolean");
      expect(cookie.zts.size).toBeGreaterThan(0);
      expect(cookie.zts.outputPath).toContain("dist-zts.js");
      expect(cookie.zts.buildArgs).toContain("--bundle");
      expect(typeof cookie.zts.stderrSummary).toBe("string");
      expect(cookie.esbuild.outputPath).toContain("dist-esbuild.js");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("size-gap.ts reports ZTS-only candidates for the target project", () => {
    const r = runBun(["run", "tests/benchmark/size-gap.ts", "--projects=safe-buffer"]);

    expect(r.status, r.stderr?.toString()).toBe(0);
    const stdout = r.stdout.toString();
    expect(stdout).toContain("safe-buffer");
    expect(stdout).toContain("ZTS-only strings");
    expect(stdout).toContain("Wrapper markers");
    expect(stdout).toContain("Top-level declarations");
  });
});
