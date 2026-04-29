/// Round 11 광역 fuzz 회귀 테스트.
///
/// 50개 fixture 각각:
///   1. ZTS 로 transpile (에러 없어야 함)
///   2. bun 으로 transpiled output 실행 (런타임 에러 없어야 함)
///   3. stdout 을 snapshot 으로 저장 (회귀 감지)
///
/// 모든 fixture 는 modern JS 기능 (Iterator helpers, Proxy, regex /v, Symbol.toPrimitive,
/// private members, parameter properties + super(), structuredClone 등) 의 transpile
/// correctness 를 검증한다.
import { describe, test, expect } from "bun:test";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { transpileAndRun } from "./helpers";

const FIXTURES_DIR = join(import.meta.dir, "fixtures/round11");
const fixtures = readdirSync(FIXTURES_DIR)
  .filter((f) => /\.(ts|tsx)$/.test(f))
  .sort();

describe("Round 11 fuzz", () => {
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
