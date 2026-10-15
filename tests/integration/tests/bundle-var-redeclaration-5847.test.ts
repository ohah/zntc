import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5847: a top-level `var` declared again with an initializer was merged into
// the first symbol without a declaration row, so the bundle tree shaker saw
// `var x = 2` as a pure statement that neither declares nor writes `x`, and
// minify-syntax pruned it (`var x = 1; var x = 2; console.log(x)` printed 1).
// Exported and imported redeclared vars broke the same way.
const script = `const r = [];
var a = 1; var a = 2; r.push(a);
var b = 1; var b; r.push(b);
var c = 1, c = 3; r.push(c);
var { d } = { d: 1 }; var { d } = { d: 4 }; r.push(d);
var [e] = [1]; var [e = 5] = []; r.push(e);
function f() {} var f = 6; r.push(f);
var g = 1; function g() {} var g = 7; r.push(g);
var h = function () { return 1; }; var h = function () { return 8; }; r.push(h());
console.log(r.join());
`;
// Module code may not mix a top-level function and var of one name, so the
// export/import cases live in their own ESM fixture.
const entry = `import { v, w } from './lib.mjs';
var z = 1; var z = v + w;
console.log(v, w, z);
`;
const lib = `export var v = 1;
var v = 2;
var w = 1; var w = 3;
export { w };
`;

describe('bundle keeps top-level var redeclarations (#5847)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const extra of [
    ['--minify-syntax'],
    ['--minify'],
    ['--minify', '--format=esm'],
    ['--minify', '--target=es5'],
  ]) {
    for (const [name, files, file] of [
      ['script', { 'entry.js': script }, 'entry.js'],
      ['esm import', { 'entry.mjs': entry, 'lib.mjs': lib }, 'entry.mjs'],
    ] as const) {
      // A script's `function f` + `var f` is a SyntaxError once emitted as an
      // ES module (esbuild emits the same), so the script runs as CJS only.
      if (name === 'script' && extra.includes('--format=esm')) continue;
      test(`${name} --bundle ${extra.join(' ')}`, async () => {
        const created = await createFixture(files);
        cleanup = created.cleanup;
        const expected = spawnSync('node', [join(created.dir, file)], { encoding: 'utf8' });
        expect(expected.status, expected.stderr).toBe(0);
        const out = join(created.dir, extra.includes('--format=esm') ? 'out.mjs' : 'out.cjs');
        const result = await runZntc(['--bundle', join(created.dir, file), ...extra, '-o', out], {
          env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
        });
        expect(result.exitCode, result.stderr).toBe(0);
        expect(result.stderr).not.toMatch(/clean=0/);
        const run = spawnSync('node', [out], { encoding: 'utf8' });
        expect(run.status, run.stderr).toBe(0);
        expect(run.stdout).toBe(expected.stdout);
      });
    }
  }
});
