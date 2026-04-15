import { describe, test, expect } from "bun:test";
import { createFixture, runZts } from "./helpers";
import { join } from "node:path";

/**
 * --block-list / blockList 통합 테스트.
 *
 * Metro resolver.blockList 호환 — 매칭되는 절대 경로는 해석 차단.
 */
describe("--block-list", () => {
  test("패턴에 매칭되는 경로는 해석 실패", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `import { x } from "./backup"; console.log(x);`,
      "backup.ts": `export const x = "backup";`,
    });
    const outFile = join(dir, "out.js");
    try {
      const { stderr } = await runZts([
        "--bundle",
        join(dir, "entry.ts"),
        "-o",
        outFile,
        "--block-list=\\/backup",
      ]);
      expect(stderr.toLowerCase()).toContain("cannot resolve");
    } finally {
      await cleanup();
    }
  });

  test("block-list 없으면 정상 해석", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `import { x } from "./backup"; console.log(x);`,
      "backup.ts": `export const x = "backup";`,
    });
    const outFile = join(dir, "out.js");
    try {
      const { exitCode, stderr } = await runZts(["--bundle", join(dir, "entry.ts"), "-o", outFile]);
      expect(exitCode).toBe(0);
      expect(stderr).not.toContain("Cannot resolve");
    } finally {
      await cleanup();
    }
  });

  test("RN 프리셋 → __tests__ 자동 차단", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `import { x } from "./__tests__/foo"; console.log(x);`,
      "__tests__/foo.ts": `export const x = "test";`,
    });
    const outFile = join(dir, "out.js");
    try {
      const { stderr } = await runZts([
        "--bundle",
        join(dir, "entry.ts"),
        "-o",
        outFile,
        "--platform=react-native",
      ]);
      // RN 프리셋의 기본 blockList가 __tests__ 차단
      expect(stderr.toLowerCase()).toContain("cannot resolve");
    } finally {
      await cleanup();
    }
  });

  test("접미사 앵커 ($) — .bak 파일 차단", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `import { x } from "./stuff.bak"; console.log(x);`,
      "stuff.bak.ts": `export const x = "bak";`,
    });
    const outFile = join(dir, "out.js");
    try {
      const { stderr } = await runZts([
        "--bundle",
        join(dir, "entry.ts"),
        "-o",
        outFile,
        "--block-list=\\.bak\\.ts$",
      ]);
      expect(stderr.toLowerCase()).toContain("cannot resolve");
    } finally {
      await cleanup();
    }
  });
});
