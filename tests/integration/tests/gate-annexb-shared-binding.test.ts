import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// Sloppy Annex B block functions share one var binding with every
// same-named block declaration and an enclosing function declaration
// (#5746, #5773, #5785). Output keeps that single identity, as esbuild and
// SWC do. The symbol gate must accept the shape: the block scope map aliases
// the var-scope function symbol, and the analyzer no longer leaves an orphan
// var-scope symbol for each extra same-named block function. Node runs the
// source natively for the expected output.
const sources: Record<string, string> = {
  'if block': `var r = [];
if (r) { function dup() { return 'if'; } r.push(dup()); }
r.push(dup());
console.log(r.join());
`,
  'sibling blocks': `var r = [];
{ function dup() { return 1; } }
{ function dup() { return 2; } }
r.push(dup());
console.log(r.join());
`,
  'outer function and blocks': `function dup() { return 'outer'; }
var r = [];
{ function dup() { return 'inner'; } r.push(dup()); }
if (r) { function dup() { return 'if'; } r.push(dup()); }
r.push(dup());
function f(x) {
  if (x) { function g() { return 'g1'; } } else { function g() { return 'g2'; } }
  switch (x) { case 1: { function s() { return 's'; } } }
  return g() + (typeof s === 'function' ? s() : '-');
}
r.push(f(1), f(0));
console.log(r.join());
`,
  'block before function': `{ function f() { return 1; } }
function f() { return 2; }
function g() { { function h() { return 1; } } { function h() { return 2; } } return h(); }
console.log(f(), g());
`,
};

describe('symbol gate accepts shared Annex B block-function bindings', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const [name, source] of Object.entries(sources)) {
    for (const target of ['esnext', 'es2015', 'es5']) {
      for (const extra of [[], ['--minify']]) {
        test(`${name} ${target} ${extra.join(' ')}`, async () => {
          const created = await createFixture({ 'entry.js': source });
          cleanup = created.cleanup;
          const expected = spawnSync('node', [join(created.dir, 'entry.js')], {
            encoding: 'utf8',
          });
          expect(expected.status, expected.stderr).toBe(0);
          const out = join(created.dir, 'out.js');
          const result = await runZntc(
            [join(created.dir, 'entry.js'), `--target=${target}`, ...extra, '-o', out],
            { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
          );
          expect(result.exitCode, result.stderr).toBe(0);
          const reports = result.stderr
            .split(/\r?\n/)
            .filter(
              (line) =>
                line.startsWith('zntc: symbol-identity ') ||
                line.startsWith('zntc: symbol-identity-post-minify '),
            );
          expect(reports.length, result.stderr).toBeGreaterThan(0);
          for (const report of reports) expect(report, result.stderr).toMatch(/clean=1(?:\s|$)/);
          const run = spawnSync('node', [out], { encoding: 'utf8' });
          expect(run.status, run.stderr).toBe(0);
          expect(run.stdout).toBe(expected.stdout);
        });
      }
    }
  }
});
