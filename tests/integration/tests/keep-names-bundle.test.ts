import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5512: --keep-names restores `.name` where each function or class is
// created, so code that runs before the end of the module (or inside a nested
// scope) sees the source name too.
const cases = [
  {
    name: 'nested declarations and reads before the end of the module',
    files: {
      'lib.js': `export function helper() { function nestedDecl() {} class NestedC {} return [nestedDecl.name, NestedC.name]; }
        export class Widget {}`,
      'entry.js': `import { helper, Widget } from './lib.js';
        function outer() {}
        class Top {}
        console.log(outer.name, Top.name, Widget.name, helper.name, helper().join());`,
    },
  },
  {
    name: 'linker renames of hoisted, assigned and static-initialized names',
    files: {
      'a.js': `export function outer() { return 1; } export const x = 1; export class C {} export const y = 2;`,
      'b.js': `export const out = [outer.name];
        function outer() {}
        const x = function () {};
        let y; y = () => {};
        class C { static n = C.name; static { out.push(this.name); } }
        out.push(x.name, y.name, C.n, C.name);`,
      'entry.js': `import * as a from './a.js'; import { out } from './b.js';
        console.log(Object.keys(a).length, out.join());`,
    },
  },
  {
    name: 'function expressions, assignments and switch-case functions',
    files: {
      'entry.js': `const x = function inner() {};
        function outer(k) {
          let z; z ??= class {};
          let w; w = () => {};
          switch (k) { case 0: return run(); case 1: function run() { return [z.name, w.name]; } }
          return [function deep() {}.name, (class K {}).name];
        }
        console.log(x.name, outer(0).join(), outer(2).join(), { m: function mm() {} }.m.name);`,
    },
  },
  {
    // The helper is raw preamble text: a source binding of the same spelling
    // must be renamed instead of shadowing or replacing it.
    name: 'source bindings named like the helper',
    files: {
      'entry.js': `function __name(a, b) { return 'user:' + b; }
        var $nm = (a, b) => 'user-min';
        function outer() { function inner() {} return inner.name; }
        console.log(__name(0, 'x'), $nm(), outer(), outer.name);`,
    },
  },
  {
    // A static `name` member defines the class's own name (esbuild skips these).
    name: 'classes with a static name member',
    files: {
      'a.js': `export class A {} export class B {} export class C {}`,
      'entry.js': `import * as m from './a.js';
        class A { static name() { return 'method'; } }
        class B { static get name() { return 'getter'; } }
        class C { static name = 'field'; }
        function wrap() { class D { static name() { return 'm2'; } } return typeof D.name; }
        console.log(Object.keys(m).length, typeof A.name, A.name(), B.name, C.name, wrap());`,
    },
  },
  {
    // ES5 block renames name through the transformer helper import while
    // --keep-names emits the preamble helper: both must coexist.
    name: 'ES5 block function renames next to keep-names',
    files: {
      'a.js': `export function f() { return 'a'; }`,
      'entry.js': `import { f } from './a.js';
        const r = f();
        { function f() { return 'inner'; } globalThis.n = f.name + ':' + f(); }
        console.log(r, globalThis.n);`,
    },
  },
] as const;

describe('--keep-names in bundles (#5512)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  const variants = [
    ...(['iife', 'cjs', 'esm'] as const).flatMap((format) =>
      [false, true].map((minify) => ({
        label: `${format}${minify ? ', minify' : ''}`,
        format,
        args: [`--format=${format}`, ...(minify ? ['--minify'] : [])],
      })),
    ),
    // No class static blocks: names are restored after the class instead.
    {
      label: 'iife, es2020, minify',
      format: 'iife',
      args: ['--format=iife', '--target=es2020', '--minify'],
    },
    { label: 'iife, es5', format: 'iife', args: ['--format=iife', '--target=es5'] },
    {
      label: 'iife, es5, minify',
      format: 'iife',
      args: ['--format=iife', '--target=es5', '--minify'],
    },
    { label: 'react-native', format: 'iife', args: ['--platform=react-native'] },
    {
      label: 'react-native, minify',
      format: 'iife',
      args: ['--platform=react-native', '--minify'],
    },
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
        const out = join(created.dir, variant.format === 'esm' ? 'out.mjs' : 'out.cjs');
        const result = await runZntc([
          '--bundle',
          join(created.dir, 'entry.js'),
          ...variant.args,
          '--keep-names',
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
