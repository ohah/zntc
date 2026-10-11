import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// An anonymous function or class takes `.name` from the binding it
// initializes. Single-use inlining and ES5 lexical renames must not change it
// unless identifiers are mangled without --keep-names (esbuild parity).
const cases = [
  {
    name: 'single-use local function and class bindings keep their names',
    files: {
      'entry.js': `const out = [];
        let a = function () {}; out.push(a.name);
        function h() { const b = () => {}; return b.name; } out.push(h());
        { const c = function () {}; out.push(c.name); }
        { const d = class {}; out.push(d.name); }
        { const e = (function () {}); out.push(e.name); }
        console.log(out.join());`,
    },
  },
  {
    name: 'renamed block lexical bindings keep their names',
    files: {
      'a.js': `export function f() { return 'a'; } export class C {} export const g = () => 1;`,
      'entry.js': `import { f, C, g } from './a.js';
        const out = [f(), C.name, g.name];
        { let f = function () {}; const g = () => {}; class C {} out.push(f.name, g.name, C.name); }
        for (let f = function () {}, i = 0; i < 1; i++) out.push(f.name);
        for (const k of [1, 2]) { const f = () => k; out.push(f.name + f()); }
        console.log(out.join());`,
    },
  },
] as const;

describe('inferred function names', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  const variants = [
    { label: 'esm', format: 'esm', args: ['--format=esm'] },
    { label: 'iife', format: 'iife', args: ['--format=iife'] },
    { label: 'iife, es5', format: 'iife', args: ['--format=iife', '--target=es5'] },
    { label: 'cjs, es5', format: 'cjs', args: ['--format=cjs', '--target=es5'] },
    { label: 'iife, keep-names', format: 'iife', args: ['--format=iife', '--keep-names'] },
    {
      label: 'esm, minify, keep-names',
      format: 'esm',
      args: ['--format=esm', '--minify', '--keep-names'],
    },
    {
      label: 'iife, es5, minify, keep-names',
      format: 'iife',
      args: ['--format=iife', '--target=es5', '--minify', '--keep-names'],
    },
    { label: 'react-native', format: 'iife', args: ['--platform=react-native'] },
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
