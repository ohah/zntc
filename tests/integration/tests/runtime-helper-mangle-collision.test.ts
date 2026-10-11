import { afterEach, describe, expect, test } from 'bun:test';
import { join } from 'node:path';
import { createFixture, runNode, runZntc } from './helpers';

// #5449: 단일 파일 minify 는 런타임 헬퍼 preamble 이름도 줄인다. 헬퍼 본문 안에서
// 다른 헬퍼(또는 자기 자신)를 참조할 때, 줄인 이름이 그 본문의 지역 변수와 같으면
// 참조가 지역 변수에 잡힌다 (`r.value instanceof i` → TypeError).
const cases = [
  {
    name: 'async generator await helper',
    source: `
      async function* run() { await 1; yield 6; }
      const it = run();
      it.next().then((r) => console.log(r.value));
    `,
    expected: '6',
  },
  {
    name: 'async generator delegating to an async iterable',
    source: `
      async function* inner() { yield 1; yield 2; }
      async function* outer() { yield* inner(); }
      (async () => {
        const out = [];
        for await (const v of outer()) out.push(v);
        console.log(out.join(','));
      })();
    `,
    expected: '1,2',
  },
  {
    name: 'for-await over a sync iterable',
    source: `
      (async () => {
        const out = [];
        for await (const v of [Promise.resolve(3), 4]) out.push(v);
        console.log(out.join(','));
      })();
    `,
    expected: '3,4',
  },
] as const;

describe('runtime helper names minified next to helper locals (#5449)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const fixture of cases) {
    for (const target of ['es2015', 'es2017'] as const) {
      test(`${fixture.name}, ${target}`, async () => {
        const created = await createFixture({ 'input.mjs': fixture.source });
        cleanup = created.cleanup;
        const output = join(created.dir, 'out.mjs');
        const result = await runZntc([
          join(created.dir, 'input.mjs'),
          `--target=${target}`,
          '--minify-identifiers',
          '-o',
          output,
        ]);
        expect(result.exitCode, result.stderr).toBe(0);
        const run = await runNode(output);
        expect(run.stdout).toBe(fixture.expected);
      });
    }
  }
});
