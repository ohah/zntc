import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5552: a native parameter initializer runs in its own environment and
// cannot see the function body's `var`s. A temp allocated there (optional
// chaining, `??`) used to be declared in the body — a ReferenceError in
// strict code (an implicit global otherwise) — and class methods aborted the
// build with `InvalidScope`. Such temps now live in the enclosing function,
// as an arrow's parameter temps do.
const source = `const a = { c: { b: 1 } }, n = { c: null };
function f1(y = a.c?.b) { return y; }
const f2 = function (y = a.c?.b) { return y; };
const o = { m(y = a.c?.b) { return y; }, set s(v = a.c?.b) { this.v = v; }, async am(y = a.c?.b) { return y; },
  *gm(y = n.c?.b ?? 3) { yield y; } };
class B { constructor(x) { this.x = x; } }
class C extends B { constructor(y = a.c?.b) { super(y); } m(y = a.c?.b) { return y; } static s(y = a.c?.b) { return y; }
  static async *ag(y = a.c?.b) { yield y; } }
async function f3(y = a.c?.b) { return y; }
function* f4(y = a.c?.b) { yield y; }
const f5 = (y = a.c?.b) => y;
function f6(y = n.c?.b, z = y ?? 2, w = a.c?.b) { return [y, z, w].join(); }
function f7(x = 1, { p = a.c?.b } = {}) { return p; }
function ev(y = a.c?.b, z = eval('y + 1')) { return [y, z].join(); }
function outer(p = a.c?.b) { function inner(q = n.c?.b ?? p) { return q; } return inner(); }
function rec(k, y = k > 0 ? rec(k - 1)?.v : { v: k }) { return { v: (y?.v ?? y) + 1 }; }
o.s = undefined;
(async () => {
  const r = [f1(), f2(), o.m(), o.v, await o.am(), o.gm().next().value, new C().x, new C().m(), C.s(),
    (await C.ag().next()).value, await f3(), f4().next().value, f5(), f6(), f7(), ev(), outer(), JSON.stringify(rec(3))];
  console.log(r.join('|'));
})();`;

describe('parameter initializer temps (#5552)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const args of [
    ['--target=es2019'],
    ['--target=es2016'],
    ['--target=es2015'],
    ['--target=es2019', '--minify'],
  ]) {
    test(args.join(' '), async () => {
      const created = await createFixture({ 'entry.mjs': source });
      cleanup = created.cleanup;
      const native = spawnSync('node', [join(created.dir, 'entry.mjs')], { encoding: 'utf8' });
      expect(native.status, native.stderr).toBe(0);
      // ESM output is strict: a temp the initializer cannot see throws.
      const out = join(created.dir, 'out.mjs');
      const result = await runZntc([
        '--bundle',
        join(created.dir, 'entry.mjs'),
        '--format=esm',
        ...args,
        '-o',
        out,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);
      const run = spawnSync('node', [out], { encoding: 'utf8' });
      expect(run.status, run.stderr).toBe(0);
      expect(run.stdout).toBe(native.stdout);
    });
  }
});
