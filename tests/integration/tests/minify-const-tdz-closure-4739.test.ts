import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #4739: minify inlined a `const`'s value into a closure written after the
// declaration, but a hoisted function (or a closure called early) can run
// before the declaration, where the `const` is still in its TDZ and reading
// it throws ReferenceError. Like esbuild, a value is inlined into a nested
// function only when the declaration leads its scope (only primitive `const`
// declarations and directives before it). Node runs the source natively for
// the expected output. (es5 turns `const` into `var`, which has no TDZ at all —
// tsc does the same — so it is not compared here.)
const source = `const out = [];
function f() {
  try { out.push(g()); } catch (e) { out.push(e.name); }
  const k = 1;
  function g() { return typeof k; }
  return g();
}
out.push(f());
try { out.push(h()); } catch (e) { out.push(e.name); }
const top = "T";
function h() { return top; }
out.push(h());
function lead() { "use strict"; const a = 2; const b = 3; return () => a + b; }
out.push(lead()());
function single() { const s = "S"; return s; }
out.push(single());
console.log(out.join());
`;

describe('minify keeps const TDZ for closures (#4739)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const target of ['esnext', 'es2015', 'es2017']) {
    for (const extra of [['--minify'], ['--minify-syntax']]) {
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

  test('a leading const is still inlined into a closure', async () => {
    const created = await createFixture({ 'entry.js': source });
    cleanup = created.cleanup;
    const out = join(created.dir, 'out.js');
    const result = await runZntc([join(created.dir, 'entry.js'), '--minify-syntax', '-o', out]);
    expect(result.exitCode, result.stderr).toBe(0);
    const code = await Bun.file(out).text();
    expect(code).toContain('() => 5');
  });
});
