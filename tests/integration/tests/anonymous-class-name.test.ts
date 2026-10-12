import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5519: lowering static fields, static blocks, private members or whole
// classes binds an anonymous class to a generated name (`_a`, `_Class`). Its
// `.name` must still be the one NamedEvaluation gives it, before any static
// element runs.
const cases = [
  {
    name: 'naming contexts',
    files: {
      'entry.js': `const out = [];
        const rec = (tag, C) => out.push(tag + '=' + C.name + '/' + C.s);
        const f = class { static s = this.name; }; rec('decl', f);
        let g; g = class { static s = this.name; }; rec('assign', g);
        const [e = class { static s = this.name; }] = []; rec('destr', e);
        function p(c = class { static s = this.name; }) { return c; } rec('param', p());
        rec('prop', { k: class { static s = this.name; } }.k);
        const o = { 2: class { static s = this.name; }, 'q-r': class { static s = this.name; } };
        rec('num', o[2]); rec('str', o['q-r']);
        class Host { static inner = class { static s = this.name; }; } rec('field', Host.inner);
        rec('none', (class { static s = this.name; }));
        const arr = []; for (let i = 0; i < 2; i++) arr.push(class { static s = this.name; }); rec('loop', arr[1]);
        class B0 {} let x; x = class extends B0 { static s = this.name; }; rec('ext', x);
        console.log(out.join(' '));`,
    },
  },
  {
    name: 'static private members, static blocks and own name members',
    files: {
      'entry.js': `const out = [];
        const rec = (tag, C) => out.push(tag + '=' + C.name + '/' + C.s);
        const pr = class { static #p = 1; static s = this.name; static q() { return pr.#p; } }; rec('priv', pr);
        let y; y ??= class { static #z = 1; static s = this.name; static z() { return this.#z; } }; rec('lassign', y);
        const sb = class { static { this.s = this.name; } }; rec('block', sb);
        const pm = class { #m() {} static s = this.name; }; rec('pmeth', pm);
        const named = class Real { static s = this.name; }; rec('named', named);
        const own = class { static name = 'own'; static s = 1; }; rec('own', own);
        console.log(out.join(' '), y.z());`,
    },
  },
  {
    // Lowering an anonymous default class used to crash (static fields) or
    // leave raw private syntax (static private members).
    name: 'anonymous export default classes',
    files: {
      'd1.js': `export default class { static #p = 1; static s = this.name; static g() { return this.#p; } }`,
      'd2.js': `export default class { static { this.s = this.name; } }`,
      'd3.js': `class Base { static t = 1; } export default class extends Base { static s = this.name; }`,
      'd4.js': `export default (class { static s = this.name; })`,
      'd5.js': `export default class { static #p = 1; static g() { return this.#p; } }`,
      'd6.js': `export default class { #p = 1; static s = 1; g() { return this.#p; } }`,
      'entry.js': `import D1 from './d1.js'; import D2 from './d2.js'; import D3 from './d3.js';
        import D4 from './d4.js'; import D5 from './d5.js'; import D6 from './d6.js';
        console.log([D1, D2, D3, D4].map((C) => C.name + '/' + C.s).join(' '), D1.g(), D5.g(), new D6().g());`,
    },
  },
] as const;

describe('anonymous class names under class lowering (#5519)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  const variants = [
    ...(['es2021', 'es2020', 'es2015', 'es5'] as const).map((target) => ({
      label: target,
      args: [`--target=${target}`],
    })),
    { label: 'es2020, minify, keep-names', args: ['--target=es2020', '--minify', '--keep-names'] },
    { label: 'es5, keep-names', args: ['--target=es5', '--keep-names'] },
    { label: 'react-native', args: ['--platform=react-native'] },
    { label: 'react-native, keep-names', args: ['--platform=react-native', '--keep-names'] },
    { label: 'es2022, keep-names', args: ['--target=es2022', '--keep-names'] },
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
