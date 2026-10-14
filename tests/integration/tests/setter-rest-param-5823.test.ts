import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5823: a setter takes exactly one formal parameter, and a rest parameter is
// not one, so `set y(...a) {}` is an early SyntaxError. The accessor check only
// counted parameters and let it through: the output failed to load, and at es5
// the rest was lowered to `arguments`, leaving an invalid `set y()`.
describe('setter rest parameter is an early error (#5823)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  const invalid: Record<string, string> = {
    'object setter': 'const o = { set y(...a) {} };\nconsole.log(o);\n',
    'class setter': 'class A { set y(...a) {} }\nconsole.log(A);\n',
    'static setter with a rest pattern': 'class A { static set y(...[a]) {} }\nconsole.log(A);\n',
    'TS typed rest': 'class A { set y(...v: number[]) {} }\nconsole.log(A);\n',
  };
  for (const [name, source] of Object.entries(invalid)) {
    for (const extra of [[], ['--bundle'], ['--target=es5']]) {
      test(`rejects ${name} ${extra.join(' ')}`, async () => {
        const file = name.startsWith('TS') ? 'entry.ts' : 'entry.js';
        const created = await createFixture({ [file]: source });
        cleanup = created.cleanup;
        const result = await runZntc([
          join(created.dir, file),
          ...extra,
          '-o',
          join(created.dir, 'out.js'),
        ]);
        expect(result.exitCode, result.stderr).not.toBe(0);
        expect(result.stderr).toContain('Setter function argument must not be a rest parameter');
      });
    }
  }

  test('still accepts single setter parameters', async () => {
    const source = `const r = [];
const o = { set a(v = 1) { r.push(v); }, set b([v]) { r.push(v); }, set c({ v }) { r.push(v); } };
o.a = undefined; o.b = [2]; o.c = { v: 3 };
class A { set d(v) { r.push(v); } }
new A().d = 4;
console.log(r.join());
`;
    const created = await createFixture({ 'entry.js': source });
    cleanup = created.cleanup;
    const out = join(created.dir, 'out.cjs');
    const result = await runZntc([join(created.dir, 'entry.js'), '--target=es5', '-o', out]);
    expect(result.exitCode, result.stderr).toBe(0);
    const run = spawnSync('node', [out], { encoding: 'utf8' });
    expect(run.status, run.stderr).toBe(0);
    expect(run.stdout).toBe('1,2,3,4\n');
  });
});
