import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5825: label names were compared as raw source text, so `lab` and `lab`
// were different labels. The analyzer reported `Undefined label` for valid code
// and missed a duplicate, es5 block scoping turned `continue outer` inside an
// extracted loop into a top-level `return` (the module silently stopped), and
// the es5 generator lowering broke the same way. Node runs the source natively
// for the expected output.
const esc = (hex: string) => `\\u${hex}`;

const source = `const r = [];
o${esc('0075')}ter: for (let i = 0; i < 3; i++) { const f = () => i; for (let j = 0; j < 3; j++) { if (j === 1) continue outer; r.push(f() * 10 + j); } }
bl${esc('{6f}')}ck: { r.push("in"); break block; }
function* g() { l${esc('0061')}b: for (let i = 0; i < 2; i++) { for (let j = 0; j < 2; j++) { yield i * 10 + j; if (j === 0) continue lab; } } }
for (const v of g()) r.push(v);
async function a() { w: for (const x of [1, 2, 3]) { await 0; const f = () => x; if (f() === 2) break ${esc('0077')}; r.push(f()); } return "a"; }
a().then((v) => { r.push(v); console.log(r.join()); });
`;

describe('escaped label names (#5825)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const extra of [
    [],
    ['--target=es5'],
    ['--target=es5', '--minify'],
    ['--target=es2016'],
    ['--bundle', '--target=es5'],
  ]) {
    test(`runs ${extra.join(' ')}`, async () => {
      const created = await createFixture({ 'entry.js': source });
      cleanup = created.cleanup;
      const expected = spawnSync('node', [join(created.dir, 'entry.js')], { encoding: 'utf8' });
      expect(expected.status, expected.stderr).toBe(0);
      const out = join(created.dir, 'out.cjs');
      const result = await runZntc([join(created.dir, 'entry.js'), ...extra, '-o', out]);
      expect(result.exitCode, result.stderr).toBe(0);
      const run = spawnSync('node', [out], { encoding: 'utf8' });
      expect(run.status, run.stderr).toBe(0);
      expect(run.stdout).toBe(expected.stdout);
    });
  }

  test('a duplicate label spelled with an escape is rejected', async () => {
    const created = await createFixture({ 'entry.js': `l${esc('0061')}b: lab: ;\n` });
    cleanup = created.cleanup;
    const result = await runZntc([
      join(created.dir, 'entry.js'),
      '-o',
      join(created.dir, 'out.js'),
    ]);
    expect(result.exitCode).not.toBe(0);
    expect(result.stderr).toContain('has already been declared');
  });
});
