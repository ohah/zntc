import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5728: inside a generator or async state machine, an assignment pattern
// whose right side held a `yield`/`await` skipped the regular destructuring
// lowering. ES5 output kept `[a, o.b] = [_a, 2]`, and a private target became
// a getter call as the target (`[_y.get(this)] = [_a]`, a SyntaxError).
// Node runs the source natively for the expected output.
const source = `const r = [];
class A {
  #y = 0;
  get #g() { return this._g; } set #g(v) { this._g = v; }
  *gen(o) {
    [this.#y] = [yield 2];
    [o.#g, this.x] = yield 3;
    ({ a: this.#y, b: { c: o.d } } = { a: yield 4, b: { c: 5 } });
    let a, b;
    [a, ...b] = [yield 6, 7, 8];
    r.push(this.#y, o._g, this.x, o.d, a, b.join('|'));
  }
  async run() { let q; [q, this.#y] = [await 1, await 2]; r.push(q, this.#y); }
}
function* plain() { let a, o = {}; [a, o.b] = [yield 1, 2]; ({ c: o.c } = { c: yield 3 }); r.push(a, o.b, o.c); }
const a = new A(); const it = a.gen(a); it.next(); it.next(9); it.next([10, 11]); it.next(12); it.next(13);
const p = plain(); p.next(); p.next('A'); p.next('C');
a.run().then(() => console.log(r.join()));
`;

describe('generator destructuring with yield lowers like any assignment (#5728)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const args of [
    ['--target=es2017'],
    ['--target=es2015', '--minify'],
    ['--target=es5'],
    ['--target=es5', '--minify'],
    ['--bundle', '--target=es5'],
  ]) {
    test(args.join(' '), async () => {
      const created = await createFixture({ 'entry.js': source });
      cleanup = created.cleanup;
      const expected = spawnSync('node', [join(created.dir, 'entry.js')], { encoding: 'utf8' });
      expect(expected.status, expected.stderr).toBe(0);
      const out = join(created.dir, 'out.cjs');
      const result = await runZntc([join(created.dir, 'entry.js'), ...args, '-o', out]);
      expect(result.exitCode, result.stderr).toBe(0);
      const run = spawnSync('node', [out], { encoding: 'utf8' });
      expect(run.status, run.stderr).toBe(0);
      expect(run.stdout).toBe(expected.stdout);
      if (args.includes('--target=es5')) {
        // No array/object assignment pattern survives in ES5 output.
        expect(readFileSync(out, 'utf8')).not.toMatch(
          /(?:^|[;{(\s])\[[\w$.]+(?:,\s*[\w$.]+)*\]\s*=[^=]/m,
        );
      }
    });
  }
});
