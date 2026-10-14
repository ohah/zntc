import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5746: in sloppy code, a function declared in a block is also assigned to
// the enclosing function's var binding when the block runs (Annex B.3.3).
// The analyzer kept its "direct if-body function" context while visiting an
// if statement's *block* body, so a block function there became a separate
// symbol: es5 renamed it (`dup$1`) and the outer binding never saw it, and
// minified output read an unbound name. Node runs the source natively for
// the expected output.
const source = `function dup() { return 'outer'; }
var r = [];
{ function dup() { return 'inner'; } r.push(dup()); }
if (r) { function dup() { return 'if'; } r.push(dup()); }
r.push(dup());
function f(x) {
  if (x) { function g() { return 'g1'; } } else { function g() { return 'g2'; } }
  if (x) function h() { return 'h'; }
  return g() + (typeof h === 'function' ? h() : '-');
}
r.push(f(1), f(0));
if (r) { function late() { return 'late'; } }
r.push(late());
console.log(r.join());
`;

describe('sloppy if-block functions keep Annex B semantics (#5746)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  const cases: [string, string, string[]][] = [];
  for (const target of ['esnext', 'es2015', 'es5']) {
    cases.push([`${target}`, source, [`--target=${target}`]]);
    cases.push([`${target} --minify`, source, [`--target=${target}`, '--minify']]);
  }

  for (const [name, code, args] of cases) {
    test(name, async () => {
      const created = await createFixture({ 'entry.js': code });
      cleanup = created.cleanup;
      const expected = spawnSync('node', [join(created.dir, 'entry.js')], { encoding: 'utf8' });
      expect(expected.status, expected.stderr).toBe(0);
      const out = join(created.dir, 'out.js');
      const result = await runZntc([join(created.dir, 'entry.js'), ...args, '-o', out]);
      expect(result.exitCode, result.stderr).toBe(0);
      const run = spawnSync('node', [out], { encoding: 'utf8' });
      expect(run.status, run.stderr).toBe(0);
      expect(run.stdout).toBe(expected.stdout);
    });
  }
});
