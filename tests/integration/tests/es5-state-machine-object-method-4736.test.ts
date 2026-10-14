import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #4736: an object literal holding an `await`/`yield` is rebuilt by the ES5
// state machine around the suspended value, and its method shorthands stayed
// in the output (`o = { w: _a, n() { … } }`), which is not ES5. Node runs the
// source natively for the expected output; ES5 output must hold no method
// shorthand (getters are ES5).
const source = `const log = [];
const base = { k() { return 'base'; } };
async function f() {
  const o = { __proto__: base, w: await 1, n() { return 2; }, get g() { return 3; }, *gen() { yield 4; }, async am() { return 5; }, k() { return super.k() + '!'; } };
  return [o.w, o.n(), o.g, [...o.gen()].join(), await o.am(), o.k()].join();
}
function* g() { const p = { v: yield 1, m() { return this.v * 2; } }; log.push(p.m()); }
const it = g(); it.next(); it.next(21);
f().then((r) => console.log(r, log.join()));
`;

describe('ES5 state machines lower object literal methods (#4736)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const extra of [[], ['--minify'], ['--bundle']]) {
    test(`es5 ${extra.join(' ')}`, async () => {
      const created = await createFixture({ 'entry.js': source });
      cleanup = created.cleanup;
      const expected = spawnSync('node', [join(created.dir, 'entry.js')], { encoding: 'utf8' });
      expect(expected.status, expected.stderr).toBe(0);
      const out = join(created.dir, 'out.cjs');
      const result = await runZntc([
        join(created.dir, 'entry.js'),
        '--target=es5',
        ...extra,
        '-o',
        out,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);
      expect(readFileSync(out, 'utf8')).not.toMatch(/[{,]\s*(?:n|m|k|gen|am)\(\)\s*\{/);
      const run = spawnSync('node', [out], { encoding: 'utf8' });
      expect(run.status, run.stderr).toBe(0);
      expect(run.stdout).toBe(expected.stdout);
    });
  }
});
