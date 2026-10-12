import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5527: a function or anonymous class under a runtime computed key is named
// by that key (NamedEvaluation). Lowering moves the value out of the naming
// position (`_a[k] = function () {}`, `__publicField(C, _b, class {})`, a
// class IIFE), so the key is captured once and the value named after it —
// a class before its static elements run.
const cases = [
  {
    name: 'class methods and accessors',
    source: `const k = 'dyn', s = Symbol('sy'), e = Symbol(), n = 1 + 1;
      class C { [k]() {} [Symbol.iterator]() {} static [s]() {} [e]() {} [n]() {} get [k + 'G']() { return 1; } set [k + 'S'](v) {} }
      const gd = (o, p) => Object.getOwnPropertyDescriptor(o, p);
      const P = C.prototype;
      console.log([P.dyn.name, P[Symbol.iterator].name, C[s].name, JSON.stringify(P[e].name), P[2].name,
        gd(P, 'dynG').get.name, gd(P, 'dynS').set.name].join('|'));`,
  },
  {
    name: 'object literal values',
    source: `const k = 'k' + 1, s = Symbol('sy'), e = Symbol(), n = 1 + 1;
      const o = { [k]: class {}, [s]: () => {}, [e]: function () {}, [n]: class { static t = this.name; },
        get [k + 'G']() { return 1; }, [k + 'F']: async function* () {} };
      const gd = (obj, p) => Object.getOwnPropertyDescriptor(obj, p);
      console.log([o.k1.name, o[s].name, JSON.stringify(o[e].name), o[2].name, o[2].t, gd(o, 'k1G').get.name,
        o.k1F.name].join('|'));`,
  },
  {
    name: 'class fields',
    source: `const k = 'k' + 1, s = Symbol('sy'), n = 1 + 1;
      class C { [k] = () => {}; static [s] = class { static t = this.name; }; static [n] = function () {};
        ['lit'] = () => {}; static plain = class {}; inst = class {}; static 3 = class { static t = this.name; }; }
      const c = new C();
      console.log([c.k1.name, C[s].name, C[s].t, C[n].name, c.lit.name, C.plain.name, c.inst.name, C[3].name,
        C[3].t].join('|'));`,
  },
  {
    // The key is read once, when the class or object literal is evaluated.
    name: 'keys reassigned later',
    source: `let k = 'a', j = 'x';
      const s = Symbol('q');
      class C { [k] = class { static t = this.name; }; static [j] = class { static u = this.name; };
        static [s] = class { static name = 'own'; }; }
      k = 'b'; j = 'y';
      const c = new C();
      const o = { [k]: class { static t = this.name; static m() {} }, [s]: class extends Object { static v = this.name; } };
      console.log([c.a.name, c.a.t, C.x.name, C.x.u, C[s].name, o.b.name, o.b.t, o[s].name, o[s].v].join('|'));`,
  },
] as const;

const variants = [
  { label: 'es2021', args: ['--target=es2021'] },
  { label: 'es2015', args: ['--target=es2015'] },
  { label: 'es2015, keep-names', args: ['--target=es2015', '--keep-names'] },
  { label: 'es5', args: ['--target=es5'] },
  { label: 'es5, minify', args: ['--target=es5', '--minify'] },
  { label: 'react-native', args: ['--platform=react-native'] },
  { label: 'react-native, minify', args: ['--platform=react-native', '--minify'] },
] as const;

describe('runtime computed key names (#5527)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  async function build(files: Record<string, string>, entry: string, args: readonly string[]) {
    const created = await createFixture({ ...files, 'package.json': '{"type":"module"}' });
    cleanup = created.cleanup;
    const out = join(created.dir, 'out.cjs');
    const result = await runZntc([
      '--bundle',
      join(created.dir, entry),
      '--format=iife',
      ...args,
      '-o',
      out,
    ]);
    expect(result.exitCode, result.stderr).toBe(0);
    const run = spawnSync('node', [out], { encoding: 'utf8' });
    expect(run.status, run.stderr).toBe(0);
    return { dir: created.dir, stdout: run.stdout };
  }

  for (const fixture of cases) {
    for (const variant of variants) {
      test(`${fixture.name}, ${variant.label}`, async () => {
        const { dir, stdout } = await build(
          { 'entry.js': fixture.source },
          'entry.js',
          variant.args,
        );
        const native = spawnSync('node', [join(dir, 'entry.js')], { encoding: 'utf8' });
        expect(native.status, native.stderr).toBe(0);
        expect(stdout).toBe(native.stdout);
      });
    }
  }

  // An own static `name` member is defined after NamedEvaluation and wins
  // (V8 renames a class under a runtime computed key afterwards; JSC and the
  // spec keep the member).
  for (const variant of variants) {
    test(`own static name members, ${variant.label}`, async () => {
      const { stdout } = await build(
        {
          'entry.js': `const s = Symbol('q'), k = 'kk';
            class C { static [s] = class { static name() { return 1; } }; static [k] = class { static get name() { return 'g'; } };
              static nm = class { static name() {} }; }
            console.log([typeof C[s].name, C[k].name, typeof C.nm.name].join('|'));`,
        },
        'entry.js',
        variant.args,
      );
      expect(stdout).toBe('function|g|function\n');
    });
  }

  // Assign semantics hoist the keys and move every field out of the class.
  for (const target of ['esnext', 'es2020', 'es5']) {
    test(`useDefineForClassFields=false, ${target}`, async () => {
      const { stdout } = await build(
        {
          'entry.ts': `const k = 'k' + 1, s = Symbol('sy'), n = 1 + 1;
            class C { [k] = () => {}; static [s] = class { static t = this.name; }; static [n] = function () {};
              ['lit'] = () => {}; static plain = class {}; }
            const c = new C();
            console.log([c.k1.name, C[s].name, C[s].t, C[n].name, c.lit.name, C.plain.name].join('|'));`,
          'tsconfig.json': '{"compilerOptions":{"useDefineForClassFields":false}}',
        },
        'entry.ts',
        [`--target=${target}`],
      );
      expect(stdout).toBe('k1|[sy]|[sy]|2|lit|plain\n');
    });
  }

  // A parameter initializer cannot read a temp hoisted into the function
  // body, so a class there is not bound to its key (this crashed with
  // `InvalidScope`); a class in a nested function body still is.
  for (const variant of variants) {
    test(`parameter initializers, ${variant.label}`, async () => {
      const { stdout } = await build(
        {
          'entry.js': `const k = 'a';
            function f(x = { [k]: class { static t = this.name; } }) { return x; }
            class Q { m(x = { [k]: class { static t = 1; } }) { return x; } }
            function g() { return { [k]: class { static t = this.name; } }; }
            console.log([typeof f().a.t, new Q().m().a.t, g().a.name, g().a.t].join('|'));`,
        },
        'entry.js',
        variant.args,
      );
      expect(stdout).toBe('string|1|a|a\n');
    });
  }

  // The key is converted once: naming must not call an object key's
  // toString again (the name then stays empty where the key is captured).
  test('an object key is converted once', async () => {
    const { stdout } = await build(
      {
        'entry.js': `let calls = 0; const key = { toString() { calls++; return 'obj'; } };
          const o = { [key]: () => {}, [key + 'x']: 1 };
          class C { [key]() {} }
          console.log(calls, ['obj', ''].includes(o.obj.name), ['obj', ''].includes(C.prototype.obj.name));`,
      },
      'entry.js',
      ['--target=es5'],
    );
    expect(stdout).toBe('3 true true\n');
  });
});
