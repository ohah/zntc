import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5667: `x` and `x` are the same identifier, but several name-keyed
// paths compared the raw spelling. es5 loop lowering missed a closure capture
// written with the other spelling (`2,2` instead of `0,1`), the semantic
// editor left the decoded scope-map key behind when it moved, renamed or
// split a binding, and output reference binding plus the symbol gate looked
// up only one spelling. Each loop below mixes spellings between the
// declaration and its uses. Node runs the source natively for the expected
// output; the symbol gate must stay clean.
const esc = (hex: string) => `\\u${hex}`;
const x = esc('0078');
const y = esc('{79}');

const source = `const r = [];
for (let ${x} = 0; x < 2; ${x}++) r.push(() => x);
for (let x = 0; x < 2; x++) r.push(() => ${x} + 10);
for (const ${y} of [5, 6]) r.push(() => y);
for (const y in { a: 1, b: 2 }) r.push(() => ${y});
for (let i = 0; i < 2; i++) { let ${x} = i * 3; r.push(() => x + 20); }
let k = 0; while (k < 2) { let x = k++; r.push(() => ${x} + 30); }
function* g() { for (let ${x} = 0; x < 2; x++) { yield 0; r.push(() => x + 40); } }
for (const _ of g());
(async () => { for (let x = 0; x < 2; ${x}++) { await 0; r.push(() => ${x} + 50); } console.log(r.map((f) => f()).join()); })();
`;

describe('escaped identifier spellings keep one identity (#5667)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const target of ['es5', 'es2015', 'esnext']) {
    for (const extra of [[], ['--minify'], ['--bundle'], ['--bundle', '--minify']]) {
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
        const run = spawnSync('node', [out], { encoding: 'utf8' });
        expect(run.status, run.stderr).toBe(0);
        expect(run.stdout).toBe(expected.stdout);
      });
    }
  }
});
