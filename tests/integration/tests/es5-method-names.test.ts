import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// ES5/Hermes class lowering defines members as `{ value: function () {} }`
// and `{ get: function () {} }`, which named every method "value" and every
// getter "get". An object literal lowered after its first computed key
// (`_a.k = function () {}`) lost the names too.
const cases = [
  {
    name: 'class methods and accessors',
    files: {
      'entry.js': `const m = 'outer';
        class Base { hello() { return 'base'; } }
        class C extends Base {
          plain() {}
          static st() {}
          *gen() {}
          async am() {}
          get acc() { return 1; }
          set acc(v) {}
          static get sacc() { return 2; }
          readsOuter() { return m; }
          hello() { return super.hello(); }
          delete() {}
          'my-method'() {}
          1.50() {}
          ünïcode() {}
        }
        const gd = (o, p) => Object.getOwnPropertyDescriptor(o, p);
        const p = C.prototype;
        console.log([p.plain.name, C.st.name, p.gen.name, p.am.name, gd(p, 'acc').get.name, gd(p, 'acc').set.name,
          gd(C, 'sacc').get.name, p.readsOuter.name, p.readsOuter(), p.hello.name, new C().hello(), p.delete.name,
          p['my-method'].name, p[1.5].name, p['ünïcode'].name].join('|'));`,
    },
  },
  {
    name: 'object literal members after a computed key',
    files: {
      'entry.js': `const k = 'dyn';
        const o = { a() {}, [k]: 1, b: function () {}, c: () => {}, get g() { return 1; }, set g(v) {}, *gen() {},
          async am() {}, 'q-r': function () {} };
        const gd = (obj, p) => Object.getOwnPropertyDescriptor(obj, p);
        console.log([o.a.name, o.b.name, o.c.name, gd(o, 'g').get.name, gd(o, 'g').set.name, o.gen.name, o.am.name,
          o['q-r'].name].join('|'));`,
    },
  },
] as const;

describe('ES5 method names', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  const variants = [
    { label: 'es5', args: ['--target=es5'] },
    // A native method keeps its name through minification (it is a property
    // key); the lowered one must too.
    { label: 'es5, minify', args: ['--target=es5', '--minify'] },
    { label: 'react-native, minify', args: ['--platform=react-native', '--minify'] },
    { label: 'es5, minify, keep-names', args: ['--target=es5', '--minify', '--keep-names'] },
    { label: 'react-native', args: ['--platform=react-native'] },
    {
      label: 'react-native, minify, keep-names',
      args: ['--platform=react-native', '--minify', '--keep-names'],
    },
    { label: 'es2015', args: ['--target=es2015'] },
  ] as const;

  for (const fixture of cases) {
    for (const variant of variants) {
      test(`${fixture.name}, ${variant.label}`, async () => {
        const created = await createFixture({
          ...fixture.files,
          'package.json': '{"type":"module"}',
        });
        cleanup = created.cleanup;
        const native = spawnSync('node', [join(created.dir, 'entry.js')], { encoding: 'utf8' });
        expect(native.status, native.stderr).toBe(0);
        const out = join(created.dir, 'out.cjs');
        const result = await runZntc([
          '--bundle',
          join(created.dir, 'entry.js'),
          '--format=iife',
          ...variant.args,
          '-o',
          out,
        ]);
        expect(result.exitCode, result.stderr).toBe(0);
        const run = spawnSync('node', [out], { encoding: 'utf8' });
        expect(run.status, run.stderr).toBe(0);
        expect(run.stdout).toBe(native.stdout);
      });
    }
  }
});
