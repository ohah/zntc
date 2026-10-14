import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #4798: in an async generator lowered to es2015/es5, the dispose step of
// `await using` (`await __callDispose(…)`) is created while the body is
// visited, after the pass that turns the body's awaits into
// `yield __await(…)`. It became a plain `yield`, so the generator yielded an
// extra `undefined` to its consumer. Node runs the source natively for the
// expected output (tsc and esbuild agree).
const source = `const log = [];
const R = (n) => ({ async [Symbol.asyncDispose]() { await null; log.push('ad' + n); }, [Symbol.dispose]() { log.push('d' + n); } });
async function* ag() {
  for (await using b of [R(1)]) { yield 'in'; }
  { await using c = R(2); using e = R(3); yield 'blk'; }
  const inner = async () => { await using q = R(4); return await 5; };
  yield await inner();
  async function nested() { await null; return 6; }
  yield await nested();
}
(async () => { for await (const v of ag()) log.push(v); console.log(JSON.stringify(log)); })();
`;

describe('await using in lowered async generators (#4798)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const target of ['es2017', 'es2015', 'es5']) {
    for (const extra of [[], ['--minify']]) {
      test(`${target} ${extra.join(' ')}`, async () => {
        const created = await createFixture({ 'entry.js': source });
        cleanup = created.cleanup;
        const expected = spawnSync('node', [join(created.dir, 'entry.js')], { encoding: 'utf8' });
        expect(expected.status, expected.stderr).toBe(0);
        const out = join(created.dir, 'out.cjs');
        const result = await runZntc([
          join(created.dir, 'entry.js'),
          `--target=${target}`,
          ...extra,
          '-o',
          out,
        ]);
        expect(result.exitCode, result.stderr).toBe(0);
        const run = spawnSync('node', [out], { encoding: 'utf8' });
        expect(run.status, run.stderr).toBe(0);
        expect(run.stdout).toBe(expected.stdout);
      });
    }
  }
});
