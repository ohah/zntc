import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #4767: in strict code (an ES module or "use strict"), a function declared
// in a block is a block-scoped binding, so it may share a name with a
// function of the enclosing function or module. The semantic analyzer aliased
// the block function to that outer function (an Annex B, sloppy-mode rule) and
// then rejected the block's own declaration as a redeclaration. Node runs the
// source natively for the expected output.
const source = `function dup() { return 'outer'; }
const r = [];
{ function dup() { return 'inner'; } r.push(dup()); }
if (true) { function dup() { return 'if'; } r.push(dup()); }
function g() { function h() { return 'h1'; } { function h() { return 'h2'; } r.push(h()); } r.push(h()); }
g();
r.push(dup());
console.log(r.join());
`;

describe('strict block functions may shadow an outer function (#4767)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const target of ['esnext', 'es2015', 'es5']) {
    for (const extra of [[], ['--minify'], ['--bundle']]) {
      test(`${target} ${extra.join(' ')}`, async () => {
        const created = await createFixture({ 'entry.mjs': source });
        cleanup = created.cleanup;
        const expected = spawnSync('node', [join(created.dir, 'entry.mjs')], { encoding: 'utf8' });
        expect(expected.status, expected.stderr).toBe(0);
        const out = join(created.dir, 'out.mjs');
        const result = await runZntc([
          join(created.dir, 'entry.mjs'),
          `--target=${target}`,
          ...extra,
          '-o',
          out,
        ]);
        expect(result.exitCode, result.stderr).toBe(0);
        expect(result.stderr).not.toContain('has already been declared');
        const run = spawnSync('node', [out], { encoding: 'utf8' });
        expect(run.status, run.stderr).toBe(0);
        expect(run.stdout).toBe(expected.stdout);
      });
    }
  }
});
