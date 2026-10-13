import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5600: a const enum declared inside a namespace is erased, so reading it as
// `N.E.A` left an undefined reference (`N is not defined`, or `N.E` undefined
// when the namespace kept other members). Reads through the namespace path are
// now inlined like `E.A`; a const enum exported from a namespace the module
// exports is kept as a regular enum because other modules read it. esbuild
// 0.27.7 prints the expected output for every case.
const singleFile = {
  'namespace path read': {
    source: 'namespace N { export const enum E { A = 1 } }\nconsole.log(N.E.A);',
    expected: '1\n',
  },
  'namespace with another export': {
    source:
      'namespace N { export const enum E { A = 1 } export const v = E.A; }\nconsole.log(N.v, N.E.A);',
    expected: '1 1\n',
  },
  'dotted namespace and computed member': {
    source:
      "namespace O.I { export const enum E { A = 2, B = A * 3 } }\nnamespace S { export const enum T { X = 'x' } }\nconsole.log(O.I.E.B, S.T['X']);",
    expected: '6 x\n',
  },
  'exported function reading the enum': {
    source:
      'namespace N { export const enum E { A = 1 } export function f() { return E.A + 1; } }\nconsole.log(N.E.A, N.f());',
    expected: '1 2\n',
  },
  'a parameter shadowing the namespace is not inlined': {
    source:
      "function f(N: any) { return N.E.A; }\nnamespace N { export const enum E { A = 1 } }\nconsole.log(f({ E: { A: 'shadowed' } }), N.E.A);",
    expected: 'shadowed 1\n',
  },
} as const;

describe('namespace const enum members (#5600)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const target of ['esnext', 'es5']) {
    for (const mode of ['transform', 'bundle']) {
      for (const [name, { source, expected }] of Object.entries(singleFile)) {
        test(`${name}, ${target}, ${mode}`, async () => {
          const created = await createFixture({ 'entry.ts': source });
          cleanup = created.cleanup;
          const out = join(created.dir, 'out.js');
          const result = await runZntc([
            ...(mode === 'bundle' ? ['--bundle'] : []),
            join(created.dir, 'entry.ts'),
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

    test(`exported namespace read from another module, ${target}`, async () => {
      const created = await createFixture({
        'ns.ts': 'export namespace N { export const enum E { A = 1 } export const v = 2; }',
        'entry.ts': "import { N } from './ns';\nconsole.log(N.E.A, N.v);",
      });
      cleanup = created.cleanup;
      const out = join(created.dir, 'out.js');
      const result = await runZntc([
        '--bundle',
        join(created.dir, 'entry.ts'),
        `--target=${target}`,
        '-o',
        out,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);
      const run = spawnSync('node', [out], { encoding: 'utf8' });
      expect(run.status, run.stderr).toBe(0);
      expect(run.stdout).toBe('1 2\n');
    });
  }
});
