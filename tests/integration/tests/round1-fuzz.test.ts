/// Round 1 fuzz 회귀 테스트 — 35 fixture (전 세션에서 7 critical PR 도출).
///
/// fixture 카테고리: TS enum / namespace / parameter property / private fields /
/// static block / getter-setter / super arrow / logical assign / decorator / JSX 등.
/// 각 fixture 는 transpile → bun 실행 → stdout snapshot 으로 회귀 감지.
import { describe, test, expect } from "bun:test";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { transpileAndRun } from "./helpers";

const FIXTURES_DIR = join(import.meta.dir, "fixtures/round1");
const fixtures = readdirSync(FIXTURES_DIR)
  .filter((f) => /\.(ts|tsx)$/.test(f))
  .sort();

describe("Round 1 fuzz", () => {
  for (const fix of fixtures) {
    test(fix, async () => {
      const source = readFileSync(join(FIXTURES_DIR, fix), "utf-8");
      const ext = fix.endsWith(".tsx") ? "tsx" : "ts";
      const r = await transpileAndRun(source, [], { ext });
      try {
        expect(r.transpileExitCode).toBe(0);
        expect(r.runStderr).toBe("");
        expect(r.runOutput).toMatchSnapshot();
      } finally {
        await r.cleanup();
      }
    });
  }
});
