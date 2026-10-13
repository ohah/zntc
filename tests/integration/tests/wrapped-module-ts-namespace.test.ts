import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5663: TS namespaces in a module the bundle wraps in `__esm` (dynamic
// import, require, after a top-level await).
//  - `export namespace N {}` declared `var N` inside the factory, but `__export`
//    reads the module-level `N`: `ReferenceError: N is not defined`.
//  - Declarations inside the namespace body (a nested enum, `const`,
//    `function`, `class`) became assignments to the module's same-named
//    bindings: the namespace's `enum E` overwrote the outer `enum E`.
// esbuild 0.27.7 prints the expected output for every case.
const cases: Record<string, { files: Record<string, string>; expected: string }> = {
  'exported namespace': {
    files: {
      'b.ts': 'export namespace N { export const v = 2 }',
      'main.ts': "import('./b').then((m) => console.log(m.N.v));",
    },
    expected: '2\n',
  },
  'dotted and merged namespaces': {
    files: {
      'b.ts':
        'export namespace A.B { export const w = 3 }\nexport namespace N { export const v = 2 }\nnamespace N { export const u = 4 }',
      'main.ts': "import('./b').then((m) => console.log(m.A.B.w, m.N.v, m.N.u));",
    },
    expected: '3 2 4\n',
  },
  'a namespace enum next to a same-named enum': {
    files: {
      'c.ts': 'export enum E { B = 2 }\nexport namespace N { export enum E { A = 1 } }',
      'main.ts': "import('./c').then((m) => console.log(m.E.B, m.E.A, m.N.E.A));",
    },
    expected: '2 undefined 1\n',
  },
  'namespace locals next to same-named module bindings': {
    files: {
      'd.ts':
        "const x = 'outer';\nfunction f() { return 'outer f'; }\nexport namespace N { const x = 'inner'; function f() { return 'inner f'; } class K { m() { return x; } } export const v = x + f() + new K().m(); }\nexport const check = () => [x, f()];",
      'main.ts': "import('./d').then((m) => console.log(m.N.v, m.check().join()));",
    },
    expected: 'innerinner finner outer,outer f\n',
  },
};

describe('TS namespaces in wrapped modules (#5663)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const format of ['esm', 'iife', 'cjs']) {
    for (const extra of [[], ['--minify'], ['--target=es5']]) {
      for (const [name, { files, expected }] of Object.entries(cases)) {
        test(`${name}, ${format}${extra.length ? `, ${extra.join(' ')}` : ''}`, async () => {
          const created = await createFixture(files);
          cleanup = created.cleanup;
          const out = join(created.dir, format === 'esm' ? 'out.mjs' : 'out.cjs');
          const result = await runZntc([
            '--bundle',
            join(created.dir, 'main.ts'),
            `--format=${format}`,
            ...extra,
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
