import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntcInDir } from './helpers';

// #5553: a computed class field key is converted to a property key once, when
// the class is defined. Lowered fields move into the constructor
// (`__publicField(this, _a, …)`) or after the class, and the temp held the
// raw key, so every instance converted it again: `toString` ran per instance
// and a function value lost its name. Expected outputs are Node's.
const keyed = `let calls = 0;
const log = [];
const key = (n) => ({ toString() { calls++; log.push('str' + n); return 'k' + n; } });
const k1 = key(1), k2 = key(2);
function ev(k, n) { log.push('ev' + n); return k; }`;

const cases = {
  'instance and static fields': {
    source: `${keyed}
class C { [ev(k1, 1)] = () => {}; static [ev(k2, 2)] = function () {}; }
new C(); new C(); const c = new C();
console.log(calls, c.k1.name, C.k2.name, log.join());`,
    expected: '2 k1 k2 ev1,str1,ev2,str2\n',
  },
  'class with a static block': {
    source: `${keyed}
class C { [ev(k1, 1)] = 1; static { log.push('block'); } static [ev(k2, 2)] = 2; }
new C(); const c = new C();
console.log(calls, c.k1, C.k2, log.join());`,
    expected: '2 1 2 ev1,str1,ev2,str2,block\n',
  },
  'class expression': {
    source: `${keyed}
const C = class { [ev(k1, 1)] = () => {}; };
new C(); const c = new C();
console.log(calls, c.k1.name, log.join());`,
    expected: '1 k1 ev1,str1\n',
  },
  'symbol and literal keys': {
    source: `const s = Symbol('s');
class C { [s] = 1; ['a' + 'b'] = 2; [3] = 3; }
const c = new C();
console.log(c[s], c.ab, c[3]);`,
    expected: '1 2 3\n',
  },
} as const;

describe('lowered computed class field keys are converted once (#5553)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const target of ['es2021', 'es2015', 'es5']) {
    for (const mode of ['transform', 'bundle', 'bundle-minify']) {
      for (const [name, { source, expected }] of Object.entries(cases)) {
        test(`${name}, ${target}, ${mode}`, async () => {
          const created = await createFixture({ 'entry.js': source });
          cleanup = created.cleanup;
          const out = join(created.dir, 'out.js');
          const args = mode === 'transform' ? [] : ['--bundle'];
          if (mode === 'bundle-minify') args.push('--minify');
          const result = await runZntcInDir(created.dir, [
            ...args,
            'entry.js',
            `--target=${target}`,
            '-o',
            out,
          ]);
          expect(result.exitCode, result.stderr).toBe(0);
          const run = spawnSync('node', [out], { encoding: 'utf8' });
          expect(run.status, run.stderr).toBe(0);
          expect(run.stdout).toBe(expected);
        });
      }
    }
  }
});
