import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5769: a target that lowers async functions to the generator state machine
// but has native block scoping (chrome49) kept source bindings in place and
// declared none of them in the state machine. The `catch (_err)` binding that
// for-of lowering creates is not a source binding, so it was never declared:
// in strict code the rethrow path threw `ReferenceError: _err is not defined`.
// Node runs the source natively for the expected output; the symbol gate must
// stay clean.
const source = `"use strict";
const log = [];
async function f() { for (const x of [1, 2]) { await 0; if (x === 2) throw new Error("boom" + x); } }
async function g() { try { await 0; throw new Error('g'); } catch (e) { log.push(e.message); } try { await 0; null.x; } catch ({ message }) { log.push(typeof message); } }
async function h() { for await (const v of [1]) { await 0; log.push(v); } }
f().catch((e) => log.push("caught " + e.message)).then(g).then(h).then(() => console.log(log.join()));
`;

describe('state machine declares synthetic catch bindings (#5769)', () => {
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
        const result = await runZntc(
          [join(created.dir, 'entry.js'), `--target=${target}`, ...extra, '-o', out],
          { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
        );
        expect(result.exitCode, result.stderr).toBe(0);
        expect(result.stderr).not.toMatch(/clean=0/);
        if (extra.length === 0) expect(result.stderr).toMatch(/clean=1/);
        const run = spawnSync('node', [out], { encoding: 'utf8' });
        expect(run.status, run.stderr).toBe(0);
        expect(run.stdout).toBe(expected.stdout);
      });
    }
  }
});
