import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// In sloppy code a function declared inside a switch case (directly or in a
// block there) is also hoisted to the enclosing function's var binding
// (Annex B.3.3 covers case clauses). The analyzer's var pre-pass did not
// descend into switch statements, so those functions never got the shared
// var-scope identity (#5785): es5 block scoping renamed each one (`s$1`, `s$2`) and a
// read after the switch threw ReferenceError. Node runs the source natively
// for the expected output (esbuild --minify agrees).
const source = `var r = [];
function f(x) {
  r.push(typeof q, typeof s);
  switch (x) { case 1: var q = 1; { function s() { return 's1'; } } case 2: { function s() { return 's2'; } } break; default: function d() { return 'd'; } }
  r.push(q, s(), typeof d);
}
f(1);
function g() { switch (0) { default: { function k() { return 'k'; } } } return k(); }
r.push(g());
console.log(r.join());
`;

describe('sloppy switch-case block functions keep Annex B hoisting (#5785)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const target of ['esnext', 'es2015', 'es5']) {
    for (const extra of [[], ['--minify'], ['--bundle', '--minify']]) {
      test(`${target} ${extra.join(' ')}`, async () => {
        const created = await createFixture({ 'entry.js': source });
        cleanup = created.cleanup;
        const expected = spawnSync('node', [join(created.dir, 'entry.js')], { encoding: 'utf8' });
        expect(expected.status, expected.stderr).toBe(0);
        const out = join(created.dir, 'out.js');
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
