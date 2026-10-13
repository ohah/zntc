import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5669: in a class with lowered private members (es2021/es2015), a static
// field's computed key was evaluated before an earlier instance field's: the
// private member lowering memoized instance field keys apart from the
// class-level key hoist, which ran first. All member keys now run once, in
// source order, before the class. The define-semantics expectation is Node's
// native run; assign semantics follow tsc (the key converts on each instance).
const source = `const log = [];
const key = (n) => ({ toString() { log.push('str' + n); return 'k' + n; } });
function ev(k, n) { log.push('ev' + n); return k; }
class C {
  #p = log.push('p');
  [ev(key(1), 1)] = log.push('f1');
  static [ev(key(2), 2)] = log.push('s2');
  static #q = log.push('q');
  [ev(key(3), 3)] = () => 3;
  [ev(key(4), 4)]() { return 4; }
  get p() { return this.#p; }
}
const c = new C(); new C();
const D = class { #z = 1; [ev(key(5), 5)] = function () {}; static [ev(key(6), 6)] = 6; };
console.log(log.join(), c.k3.name, new D().k5.name, Object.keys(c).join());
`;
const assignExpected =
  'ev1,ev2,ev3,ev4,str4,s2,str2,q,p,f1,str1,str3,p,f1,str1,str3,ev5,ev6,str6   k1,k3\n';

describe('computed member keys run in source order with private members (#5669)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const target of ['es2021', 'es2015', 'es5']) {
    for (const extra of [[], ['--minify'], ['--use-define-for-class-fields=false']]) {
      test(`${target} ${extra.join(' ')}`, async () => {
        const created = await createFixture({ 'entry.js': source });
        cleanup = created.cleanup;
        const native = spawnSync('node', [join(created.dir, 'entry.js')], { encoding: 'utf8' });
        expect(native.status, native.stderr).toBe(0);
        const out = join(created.dir, 'out.cjs');
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
        expect(run.stdout).toBe(
          extra.includes('--use-define-for-class-fields=false') ? assignExpected : native.stdout,
        );
      });
    }
  }
});
