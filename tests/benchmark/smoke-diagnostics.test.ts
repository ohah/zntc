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

  test("size-gap.ts reports CJS export pattern audit for target projects", () => {
    const r = runBun(["run", "tests/benchmark/size-gap.ts"]);

    expect(r.status, r.stderr?.toString()).toBe(0);
    const stdout = r.stdout.toString();
    expect(stdout).toContain("safe-buffer");
    expect(stdout).toContain("cookie");
    expect(stdout).toContain("path-to-regexp");
    expect(stdout).toContain("object-assign");
    expect(stdout).toContain("merge-descriptors");
    expect(stdout).toContain("ZTS-only strings");
    expect(stdout).toContain("Wrapper markers");
    expect(stdout).toContain("Top-level declarations");
    expect(stdout).toContain("CJS export pattern audit");
    expect(stdout).toContain("Pattern counts:");
    expect(stdout).toMatch(/exports\.x =: \d+/);
    expect(stdout).toMatch(/module\.exports\.x =: \d+/);
    expect(stdout).toMatch(/module\.exports =: \d+/);
    expect(stdout).toMatch(/module\.exports = \{ \.\.\. \}: \d+/);
    expect(stdout).toMatch(/Object\.defineProperty\(\.\.\., \{ value \}\): \d+/);
    expect(stdout).toMatch(/Object\.defineProperty\(\.\.\., \{ value: member \}\): \d+/);
    expect(stdout).toMatch(/Object\.defineProperty\(\.\.\., \{ get \}\): \d+/);
    expect(stdout).toMatch(/Remaining ZTS export markers:\n(?:  - .+\n?)+/);
    expect(stdout).toMatch(/Removed dead marker candidates:\n(?:  - .+\n?)+/);
    expect(stdout).toMatch(
      /## safe-buffer[\s\S]*Removed dead marker candidates:[\s\S]*exports\.Buffer =/,
    );
    expect(stdout).toMatch(
      /## cookie[\s\S]*Remaining ZTS export markers:[\s\S]*exports\.serialize =/,
    );
    expect(stdout).toMatch(
      /## cookie[\s\S]*Removed dead marker candidates:[\s\S]*exports\.parseCookie =/,
    );
    expect(stdout).toMatch(
      /## path-to-regexp[\s\S]*Remaining ZTS export markers:[\s\S]*exports\.match =/,
    );
    expect(stdout).toMatch(
      /## path-to-regexp[\s\S]*Removed dead marker candidates:[\s\S]*exports\.compile =/,
    );
    expect(stdout).toMatch(
      /## object-assign[\s\S]*CJS export pattern audit[\s\S]*module\.exports =: 1/,
    );
    expect(stdout).toMatch(
      /## merge-descriptors[\s\S]*CJS export pattern audit[\s\S]*module\.exports =: 1/,
    );
  });

  test("--filter accepts comma-separated patterns and produces multiple results", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-smoke-multi-"));
    const jsonPath = join(dir, "report.json");
    try {
      const r = runBun([
        "run",
        "tests/benchmark/smoke.ts",
        "--filter=safe-buffer,cookie",
        `--json=${jsonPath}`,
      ]);

      expect(r.status, r.stderr?.toString()).toBe(0);
      const report = JSON.parse(readFileSync(jsonPath, "utf-8"));
      const names = report.results.map((entry: { project: string }) => entry.project);
      expect(names).toContain("safe-buffer");
      expect(names).toContain("cookie");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
