import { describe, test, expect } from "bun:test";
import { createFixture, ZTS_BIN } from "./helpers";
import { join } from "node:path";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { spawn, type ChildProcess } from "node:child_process";

/**
 * --watch-json 통합 테스트
 *
 * --watch-json은 --watch + NDJSON stdout 출력 모드.
 * stdout에는 NDJSON 이벤트만 출력되어야 하며,
 * 인간용 상태 메시지나 raw 번들 내용이 섞이면 안 됨.
 *
 * bun test에서 child process stdout pipe가 제대로 동작하지 않는 이슈가 있어
 * shell 경유 파일 리다이렉트 방식으로 NDJSON 출력을 검증한다.
 */

/** zts --watch-json을 shell 경유로 spawn하고 stdout을 파일로 리다이렉트 */
function spawnWatchJson(args: string[], jsonOutPath: string): ChildProcess {
  const quotedArgs = args.map((a) => `"${a}"`).join(" ");
  return spawn("sh", ["-c", `"${ZTS_BIN}" ${quotedArgs} > "${jsonOutPath}" 2>/dev/null`]);
}

/** NDJSON 출력 파일에서 특정 라인이 나타날 때까지 폴링 */
async function waitForNdjsonLines(
  jsonOutPath: string,
  minLines: number,
  timeoutMs = 10000,
): Promise<Record<string, unknown>[]> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (existsSync(jsonOutPath)) {
      const content = readFileSync(jsonOutPath, "utf8").trim();
      if (content) {
        const lines = content.split("\n").filter(Boolean);
        if (lines.length >= minLines) {
          return lines.map((l) => JSON.parse(l));
        }
      }
    }
    await new Promise((r) => setTimeout(r, 200));
  }
  const content = existsSync(jsonOutPath) ? readFileSync(jsonOutPath, "utf8") : "(file not found)";
  throw new Error(
    `Timeout waiting for ${minLines} NDJSON line(s). Content: ${JSON.stringify(content)}`,
  );
}

/** 프로세스를 kill하고 종료를 기다림 */
function killAndWait(proc: ChildProcess): Promise<void> {
  return new Promise<void>((resolve) => {
    if (proc.exitCode !== null) {
      resolve();
      return;
    }
    proc.on("exit", () => resolve());
    setTimeout(resolve, 2000);
    proc.kill();
  });
}

describe("--watch-json", () => {
  test("initial build emits ready event with files and bytes", { timeout: 30000 }, async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `export const hello = "world";`,
    });
    const outFile = join(dir, "out.js");
    const jsonOut = join(dir, "ndjson.txt");

    const proc = spawnWatchJson(
      ["--bundle", join(dir, "entry.ts"), "-o", outFile, "--watch-json"],
      jsonOut,
    );

    try {
      const events = await waitForNdjsonLines(jsonOut, 1);
      const ready = events[0];

      expect(ready.type).toBe("ready");
      expect(typeof ready.files).toBe("number");
      expect(ready.files as number).toBeGreaterThan(0);
      expect(typeof ready.bytes).toBe("number");
      expect(ready.bytes as number).toBeGreaterThan(0);

      // 초기 빌드에서 번들 파일이 생성되어야 함
      const bundled = readFileSync(outFile, "utf8");
      expect(bundled).toContain("hello");
    } finally {
      await killAndWait(proc);
      await cleanup();
    }
  });

  test(
    "stdout contains only valid NDJSON, no human-readable messages",
    { timeout: 30000 },
    async () => {
      const { dir, cleanup } = await createFixture({
        "entry.ts": `export const x = 42;`,
      });
      const outFile = join(dir, "out.js");
      const jsonOut = join(dir, "ndjson.txt");

      const proc = spawnWatchJson(
        ["--bundle", join(dir, "entry.ts"), "-o", outFile, "--watch-json"],
        jsonOut,
      );

      try {
        const events = await waitForNdjsonLines(jsonOut, 1);
        const ready = events[0];

        // 첫 번째 stdout 라인이 valid JSON이어야 함
        expect(ready.type).toBe("ready");
        // "Bundled →" 같은 인간용 메시지가 없어야 함
        expect(JSON.stringify(ready)).not.toContain("Bundled");
      } finally {
        await killAndWait(proc);
        await cleanup();
      }
    },
  );

  test("rebuild event emitted on file change", { timeout: 30000 }, async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `export const v = "initial";`,
    });
    const outFile = join(dir, "out.js");
    const jsonOut = join(dir, "ndjson.txt");

    const proc = spawnWatchJson(
      ["--bundle", join(dir, "entry.ts"), "-o", outFile, "--watch-json"],
      jsonOut,
    );

    try {
      // 1) ready 이벤트 수신
      const readyEvents = await waitForNdjsonLines(jsonOut, 1);
      expect(readyEvents[0].type).toBe("ready");

      // 2) 파일 변경 (watch 폴링 간격 500ms 이후 감지됨)
      await new Promise((r) => setTimeout(r, 1000));
      writeFileSync(join(dir, "entry.ts"), `export const v = "changed";`);

      // 3) rebuild 이벤트 수신 (ready + rebuild = 2 lines)
      const events = await waitForNdjsonLines(jsonOut, 2, 15000);
      const rebuild = events[1];
      expect(rebuild.type).toBe("rebuild");
      expect(rebuild.success).toBe(true);
      expect(Array.isArray(rebuild.changed)).toBe(true);
      expect((rebuild.changed as string[]).length).toBeGreaterThan(0);
      expect(typeof rebuild.bytes).toBe("number");

      // 4) 출력 파일이 갱신되어야 함
      const updated = readFileSync(outFile, "utf8");
      expect(updated).toContain("changed");
    } finally {
      await killAndWait(proc);
      await cleanup();
    }
  });

  test("no raw bundle content on stdout without -o flag", { timeout: 30000 }, async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `export const big = "${"x".repeat(100)}";`,
    });
    const jsonOut = join(dir, "ndjson.txt");

    const proc = spawnWatchJson(["--bundle", join(dir, "entry.ts"), "--watch-json"], jsonOut);

    try {
      const events = await waitForNdjsonLines(jsonOut, 1);
      const ready = events[0];

      // stdout 첫 줄이 valid JSON이어야 하고, raw JS 코드가 아님
      expect(ready.type).toBe("ready");
      expect(typeof ready.bytes).toBe("number");

      // stdout 전체가 valid NDJSON인지 확인 (raw 번들이 섞이면 안 됨)
      const content = readFileSync(jsonOut, "utf8").trim();
      for (const line of content.split("\n").filter(Boolean)) {
        expect(() => JSON.parse(line)).not.toThrow();
      }
    } finally {
      await killAndWait(proc);
      await cleanup();
    }
  });

  test("code splitting with --outdir emits ready event", { timeout: 30000 }, async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `import("./lazy").then(m => m.default());`,
      "lazy.ts": `export default () => console.log("lazy");`,
    });
    const outDir = join(dir, "dist");
    const jsonOut = join(dir, "ndjson.txt");

    const proc = spawnWatchJson(
      [
        "--bundle",
        join(dir, "entry.ts"),
        "--splitting",
        "--outdir",
        outDir,
        "--format=esm",
        "--watch-json",
      ],
      jsonOut,
    );

    try {
      const events = await waitForNdjsonLines(jsonOut, 1);
      const ready = events[0];

      expect(ready.type).toBe("ready");
      expect(ready.files as number).toBeGreaterThan(0);
      expect(ready.bytes as number).toBeGreaterThan(0);
    } finally {
      await killAndWait(proc);
      await cleanup();
    }
  });
});
