import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5773: in sloppy code, several blocks that declare a function with the same
// name all assign one enclosing var binding when they run (Annex B.3.3). The
// analyzer gives them that binding's SymbolId, but output binding resolution
// moved the identity into the first block and split each later block off as a
// new binding. Identifier mangling then named them apart (`t`, `n`) and the
// outer reads saw only the first block's function. Node runs the source
// natively for the expected output (esbuild --minify agrees).
const source = `var r = [];
function nested() {
  var out = [];
  { function g() { return 1; } out.push(g()); }
  { function g() { return 2; } out.push(g()); }
  out.push(g());
  if (out) { function h() { return 'h1'; } } else { function h() { return 'h2'; } }
  out.push(h());
  return out.join('/');
}
r.push(nested());
try { r.push(typeof early); } catch (e) { r.push(e.name); }
{ function early() { return 'e1'; } }
for (var i = 0; i < 2; i++) { { function loopy() { return 'L' + i; } } }
r.push(early(), loopy());
var vv = 0;
{ function vv() { return 'v1'; } }
{ function vv() { return 'v2'; } }
r.push(typeof vv === 'function' ? vv() : vv);
{ function* gen() { yield 'g1'; } r.push(gen().next().value); }
{ async function af() {} r.push(typeof af); }
label: { function lab() { return 'lab1'; } }
{ function lab() { return 'lab2'; } }
r.push(lab());
console.log(r.join());
`;

describe('sloppy sibling block functions share one mangled name (#5773)', () => {
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
