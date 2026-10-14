import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #4734: a target that lowers async functions to the generator state machine
// but has native block scoping (chrome49) lost per-iteration loop bindings:
// the state machine hoists `let`/`const` to one function-level `var`, so every
// closure made in the loop saw the last value. The body is now extracted per
// iteration (`_loop`, delegated with `yield*`) whatever the target's block
// scoping, as es5 already did. Node runs the source natively for the
// expected output.
const source = `const out = [];
async function f() {
  for (let i = 0; i < 2; i++) { await 0; setTimeout(() => out.push('a' + i)); }
  for (const x of [1, 2]) { await 0; setTimeout(() => out.push('b' + x)); }
  for (let j = 0; j < 3; j++) { if (j === 1) continue; if (j === 2) break; await 0; let k = j * 10; setTimeout(() => out.push('c' + k)); }
  for (let m = 0; m < 2; m++) { await 0; if (m === 1) return setTimeout(() => out.push('r' + m)); }
}
function* g() { for (let i = 0; i < 2; i++) { yield i; out.push(() => i); } }
f().then(() => setTimeout(() => { for (const v of g()); console.log(out.map((v) => (typeof v === 'function' ? 'g' + v() : v)).join()); }, 10));
`;

describe('state machine loops keep per-iteration bindings (#4734)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const target of ['chrome49', 'es5', 'es2015']) {
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
