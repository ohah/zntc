/// Round 2 fuzz 회귀 테스트 — 35 fixture (전 세션 검증 결과 0 ZTS-DIFF, clean).
///
/// fixture 카테고리: namespace 병합/중첩, abstract override, using/await using, iterator
/// helpers, set methods, regex /v, import.meta.url, /* @__PURE__ */ annotation 등 ES2024+.
/// clean baseline 을 회귀로 보호.
import { describe, test, expect } from 'bun:test';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { transpileAndRun } from './helpers';

const FIXTURES_DIR = join(import.meta.dir, 'fixtures/round2');
const fixtures = readdirSync(FIXTURES_DIR)
  .filter((f) => /\.(ts|tsx)$/.test(f))
  .sort();

describe('Round 2 fuzz', () => {
  for (const fix of fixtures) {
    test(fix, async () => {
      const source = readFileSync(join(FIXTURES_DIR, fix), 'utf-8');
      const ext = fix.endsWith('.tsx') ? 'tsx' : 'ts';
      const r = await transpileAndRun(source, [], { ext });
      try {
        expect(r.transpileExitCode).toBe(0);
        expect(r.runStderr).toBe('');
        expect(r.runOutput).toMatchSnapshot();
      } finally {
        await r.cleanup();
      }
    });
  }
});
