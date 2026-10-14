import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #4799: an ES5-lowered array destructuring assignment evaluated to its
// `__read` copy instead of the right side (`([a] = arr) === arr` was false).
// The right side now goes into a temp that the sequence returns, only where
// the value is read: an expression statement keeps its former shape. Node
// runs the source natively for the expected output.
const source = `const arr = [1, 2, 3], set = new Set([4, 5]);
let a, b, c;
const x = [a] = arr;
console.log(([a, ...b] = arr) === arr, ([a, b] = arr) === arr, ([a, ...b] = set) === set, x === arr);
[a, b] = [b, a];
for (let i = 0; i < 1; [a, b] = [b, a], i++) {}
function f() { return [c] = 'hi'; }
console.log(a, b, f(), c, JSON.stringify(({ a } = { a: 9 })));
`;

describe('ES5 array destructuring assignment value (#4799)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const extra of [[], ['--minify'], ['--bundle']]) {
    test(`es5 ${extra.join(' ')}`, async () => {
      const created = await createFixture({ 'entry.js': source });
      cleanup = created.cleanup;
      const expected = spawnSync('node', [join(created.dir, 'entry.js')], { encoding: 'utf8' });
      expect(expected.status, expected.stderr).toBe(0);
      const out = join(created.dir, 'out.cjs');
      const result = await runZntc([
        join(created.dir, 'entry.js'),
        '--target=es5',
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

  test('a discarded swap gets no value temp', async () => {
    const created = await createFixture({
      'entry.js': 'let a = 1, b = 2;\n[a, b] = [b, a];\nconsole.log(a, b);\n',
    });
    cleanup = created.cleanup;
    const out = join(created.dir, 'out.cjs');
    const result = await runZntc([join(created.dir, 'entry.js'), '--target=es5', '-o', out]);
    expect(result.exitCode, result.stderr).toBe(0);
    expect(readFileSync(out, 'utf8')).toContain('_a = __read([b, a], 2),a = _a[0],b = _a[1],_a;');
  });
});
