import { describe, test, expect } from "bun:test";
import {
  createFixture,
  createNdjsonTail,
  killAndWait,
  spawnWatchJson,
  waitForNdjsonLines,
} from "./helpers";
import { join } from "node:path";
import { readFileSync, writeFileSync } from "node:fs";

/**
 * --watch-json 통합 테스트
 *
 * --watch-json은 --watch + NDJSON stdout 출력 모드.
 * stdout에는 NDJSON 이벤트만 출력되어야 하며,
 * 인간용 상태 메시지나 raw 번들 내용이 섞이면 안 됨.
 */

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
    const tail = createNdjsonTail();

    try {
      const events = await waitForNdjsonLines(jsonOut, 1, tail);
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
      const tail = createNdjsonTail();

      try {
        const events = await waitForNdjsonLines(jsonOut, 1, tail);
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
    const tail = createNdjsonTail();

    try {
      // 1) ready 이벤트 수신
      const readyEvents = await waitForNdjsonLines(jsonOut, 1, tail);
      expect(readyEvents[0].type).toBe("ready");

      // 2) 파일 변경 (watch 폴링 간격 500ms 이후 감지됨)
      await new Promise((r) => setTimeout(r, 1000));
      writeFileSync(join(dir, "entry.ts"), `export const v = "changed";`);

      // 3) rebuild 이벤트 수신 (ready + rebuild = 2 lines)
      const events = await waitForNdjsonLines(jsonOut, 2, tail, { timeoutMs: 15000 });
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
    const tail = createNdjsonTail();

    try {
      const events = await waitForNdjsonLines(jsonOut, 1, tail);
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
    const tail = createNdjsonTail();

    try {
      const events = await waitForNdjsonLines(jsonOut, 1, tail);
      const ready = events[0];

      expect(ready.type).toBe("ready");
      expect(ready.files as number).toBeGreaterThan(0);
      expect(ready.bytes as number).toBeGreaterThan(0);
    } finally {
      await killAndWait(proc);
      await cleanup();
    }
  });

  test("--watch-folder: 그래프 밖 파일 변경도 rebuild 트리거", { timeout: 30000 }, async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `export const v = "initial";`,
      "assets/config.json": `{"k":1}`,
    });
    const outFile = join(dir, "out.js");
    const jsonOut = join(dir, "ndjson.txt");
    const assetsDir = join(dir, "assets");

    const proc = spawnWatchJson(
      [
        "--bundle",
        join(dir, "entry.ts"),
        "-o",
        outFile,
        "--watch-json",
        `--watch-folder=${assetsDir}`,
      ],
      jsonOut,
    );
    const tail = createNdjsonTail();

    try {
      const readyEvents = await waitForNdjsonLines(jsonOut, 1, tail);
      expect(readyEvents[0].type).toBe("ready");
      // entry 파일 1개만 그래프에 있지만 watch-folder로 config.json도 감시 대상에 추가됨
      expect((readyEvents[0].files as number) >= 2).toBe(true);

      // 그래프 밖 파일 변경
      await new Promise((r) => setTimeout(r, 1000));
      writeFileSync(join(assetsDir, "config.json"), `{"k":2}`);

      const events = await waitForNdjsonLines(jsonOut, 2, tail, { timeoutMs: 15000 });
      const rebuild = events[1];
      expect(rebuild.type).toBe("rebuild");
      expect(rebuild.success).toBe(true);
    } finally {
      await killAndWait(proc);
      await cleanup();
    }
  });
});
