import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5803: in one var scope, several function declarations of a name — or a
// `var` and a function declaration — are one runtime binding. The analyzer
// made a symbol per declaration, leaving orphan symbols (gate
// `symbol-not-in-either-map`), and a bundle with syntax minification then
// dropped declarations whose symbol looked unused (`var k = function…` lost
// to `function k`, a function declaration removed). Node runs the sources
// natively for the expected output; the symbol gate must stay clean.
const sources: Record<string, string> = {
  'duplicate functions': `var r = [];
r.push(f());
function f() { return 1; }
r.push(f());
function f() { return 2; }
r.push(typeof g, g());
async function g() {}
function g() { return 'g2'; }
function outer() { function h() { return 'h1'; } function h() { return 'h2'; } return h(); }
r.push(outer());
var k = function () { return 'kv'; };
function k() { return 'kf'; }
r.push(k());
console.log(r.join());
`,
  'var and function': `var r = [];
r.push(typeof a);
var a = 1;
function a() {}
r.push(typeof a);
function b() {}
var b;
r.push(typeof b);
var c = function () { return 'cv'; };
function c() { return 'cf'; }
r.push(c());
function d() { return 'df'; }
var d = function () { return 'dv'; };
r.push(d());
function inner() { var x = 1; function x() {} var y; function y() { return 'y'; } return typeof x + y(); }
r.push(inner());
console.log(r.join());
`,
};

describe('var-scope duplicate declarations share one binding (#5803)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const [name, source] of Object.entries(sources)) {
    for (const target of ['esnext', 'es2015', 'es5']) {
      for (const extra of [[], ['--minify'], ['--bundle'], ['--bundle', '--minify']]) {
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
          expect(result.stderr).not.toMatch(/clean=0/);
          const run = spawnSync('node', [out], { encoding: 'utf8' });
          expect(run.status, run.stderr).toBe(0);
          expect(run.stdout).toBe(expected.stdout);
        });
      }
    }
  }
});
