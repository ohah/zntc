import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5665
//  - `import { type T } from './t'` names only types: tsc and esbuild (without
//    verbatimModuleSyntax) drop the whole import, so `t` is not evaluated. The
//    bundle kept the import record and ran `t`.
//  - A const enum member initialized with a no-substitution template literal
//    is a constant: the declaration was erased without inlining the member
//    (`E is not defined`).
const t = "console.log('t evaluated');\nexport type T = number;\nexport const v = 1;";

describe('inline type-only imports are dropped (#5665)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  const cases: Record<string, { entry: string; expected: string; args?: string[] }> = {
    'every specifier an inline type': {
      entry: "import { type T } from './t';\nconst a: T = 1;\nconsole.log('main', a);",
      expected: 'main 1\n',
    },
    'several inline types': {
      entry:
        "import { type T, type T as U } from './t';\nconst a: T = 1, b: U = 2;\nconsole.log('main', a + b);",
      expected: 'main 3\n',
    },
    'an inline type next to a value': {
      entry: "import { type T, v } from './t';\nconst a: T = v;\nconsole.log('main', a);",
      expected: 't evaluated\nmain 1\n',
    },
    'an empty import stays a side-effect import': {
      entry: "import {} from './t';\nconsole.log('main');",
      expected: 't evaluated\nmain\n',
    },
    'verbatimModuleSyntax keeps the module': {
      entry: "import { type T } from './t';\nconst a: T = 1;\nconsole.log('main', a);",
      expected: 't evaluated\nmain 1\n',
      args: ['--verbatim-module-syntax'],
    },
  };
  for (const format of ['esm', 'iife', 'cjs']) {
    for (const [name, { entry, expected, args = [] }] of Object.entries(cases)) {
      test(`${name}, ${format}`, async () => {
        const created = await createFixture({ 't.ts': t, 'entry.ts': entry });
        cleanup = created.cleanup;
        const out = join(created.dir, format === 'esm' ? 'out.mjs' : 'out.cjs');
        const result = await runZntc([
          '--bundle',
          join(created.dir, 'entry.ts'),
          `--format=${format}`,
          ...args,
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
});

describe('const enum members initialized with a template literal (#5665)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  const source =
    'const enum E { A = 1, B = `x`, C = `a b` }\nconsole.log(E.A, E.B, E.C);\nnamespace N { export const enum F { D = `y` } }\nconsole.log(N.F.D);';
  for (const args of [[], ['--bundle'], ['--target=es5'], ['--minify']]) {
    test(`${args.join(' ') || 'transform'}`, async () => {
      const created = await createFixture({ 'entry.ts': source });
      cleanup = created.cleanup;
      const out = join(created.dir, 'out.js');
      const result = await runZntc([join(created.dir, 'entry.ts'), ...args, '-o', out]);
      expect(result.exitCode, result.stderr).toBe(0);
      const run = spawnSync('node', [out], { encoding: 'utf8' });
      expect(run.status, run.stderr).toBe(0);
      expect(run.stdout).toBe('1 x a b\ny\n');
    });
  }
});
