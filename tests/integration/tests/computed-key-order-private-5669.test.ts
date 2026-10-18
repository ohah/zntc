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

const computedFunctionNameCases = [
  {
    name: 'instance arrow field with a function key',
    source: `function getKey() { return 'first'; }
class C { #private; [getKey()] = () => 1; }
console.log(new C().first.name);`,
  },
  {
    name: 'function expression field with a closure key',
    source: `const keyName = 'second';
function getKey() { return keyName; }
class C { #private; [getKey()] = function () { return 2; }; }
console.log(new C().second.name);`,
  },
  {
    name: 'async field with a symbol key',
    source: `const key = Symbol('third');
function getKey() { return key; }
class C { #private; [getKey()] = async () => 3; }
const c = new C(); console.log(c[key].name);`,
  },
  {
    name: 'generator field with a numeric key',
    source: `function getKey() { return 42; }
class C { #private; [getKey()] = function* () { yield 4; }; }
console.log(new C()[42].name);`,
  },
  {
    name: 'multiple instance fields use their own keys',
    source: `let index = 0;
function getKey() { return ['left', 'right'][index++]; }
class C { #private; [getKey()] = () => 5; [getKey()] = () => 6; }
const c = new C(); console.log(c.left.name, c.right.name, index);`,
  },
  {
    name: 'async function expression field value',
    source: `function getKey() { return 'asyncFunction'; }
class C { #private; [getKey()] = async function () { return 6; }; }
console.log(new C().asyncFunction.name);`,
  },
  {
    name: 'computed field inside a class factory',
    source: `function getKey() { return 'nested'; }
function make() { class C { #private; [getKey()] = () => 7; } return new C(); }
console.log(make().nested.name);`,
  },
  {
    name: 'computed key parameter survives an inner class',
    source: `function make(getKey) { class C { #private; [getKey()] = () => 8; } return new C(); }
console.log(make(() => 'parameter').parameter.name);`,
  },
  {
    name: 'static function field keeps its computed name',
    source: `function getKey() { return 'staticFunction'; }
class C { #private; static [getKey()] = () => 9; }
console.log(C.staticFunction.name);`,
  },
  {
    name: 'method and instance field keys keep evaluation order',
    source: `const events = [];
function getKey(name) { events.push(name); return name; }
class C { #private; [getKey('method')]() {} [getKey('field')] = () => 10; }
const c = new C(); console.log(events.join(','), c.field.name);`,
  },
] as const;

describe('computed-key function names survive private-field lowering (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const fixture of computedFunctionNameCases) {
    test(fixture.name, async () => {
      const created = await createFixture({ 'entry.js': fixture.source });
      cleanup = created.cleanup;
      const native = spawnSync('node', [join(created.dir, 'entry.js')], { encoding: 'utf8' });
      expect(native.status, native.stderr).toBe(0);

      const out = join(created.dir, 'out.cjs');
      const result = await runZntc([join(created.dir, 'entry.js'), '--target=es2021', '-o', out]);
      expect(result.exitCode, result.stderr).toBe(0);

      const transformed = spawnSync('node', [out], { encoding: 'utf8' });
      expect(transformed.status, transformed.stderr).toBe(0);
      expect(transformed.stdout).toBe(native.stdout);
    });
  }
});
