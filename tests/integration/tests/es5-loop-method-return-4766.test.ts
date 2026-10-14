import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #4766: when ES5 lowering moved a loop body into a `_loop` function (for a
// per-iteration binding), its control-flow scan counted a `return` inside a
// class or object method as the loop's own `return`, and emitted
// `if (typeof _ret === "object") return _ret.v;` at module top level — a
// SyntaxError in an ES module. Node runs the source natively for the
// expected output.
const source = `const f = [];
for (var i = 0; i < 2; i++) {
  class C { m() { return i; } get g() { return 1; } }
  const o = { k() { return i; }, get v() { return 2; } };
  const c = C;
  f.push(() => [c === C, o.k(), o.v].join('/'));
}
function first(xs) {
  for (const x of xs) {
    const g = () => x;
    if (x > 1) return g();
  }
  return -1;
}
console.log(f.map((g) => g()).join(), first([1, 2, 3]));
`;

describe('ES5 _loop ignores returns inside methods (#4766)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const extra of [[], ['--minify']]) {
    test(`es5 module ${extra.join(' ')}`, async () => {
      const created = await createFixture({ 'entry.mjs': source });
      cleanup = created.cleanup;
      const expected = spawnSync('node', [join(created.dir, 'entry.mjs')], { encoding: 'utf8' });
      expect(expected.status, expected.stderr).toBe(0);
      const out = join(created.dir, 'out.mjs');
      const result = await runZntc([
        join(created.dir, 'entry.mjs'),
        '--target=es5',
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
});
