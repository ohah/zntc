import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5581: TypeScript drops an import whose bindings are all used only as types
// in the source, so its module is not evaluated — the same as `import type`.
// The bundler evaluated such modules (their side effects ran). esbuild 0.27.7
// gives the expected output for every case below.
const cases = {
  'unused named import of an ESM module': {
    'dep.mjs': "console.log('dep');\nexport const v = 1;",
    'entry.ts': "import { v } from './dep.mjs';\nconsole.log('main');",
    expected: 'main\n',
  },
  'named import used as `typeof` only': {
    'dep.ts': "export const v = 1;\nconsole.log('dep');",
    'entry.ts': "import { v } from './dep';\ndeclare const y: typeof v;\nconsole.log('main');",
    expected: 'main\n',
  },
  'class imported for a type annotation only': {
    'dep.ts': "export class C { n = 1; }\nconsole.log('dep');",
    'entry.ts':
      "import { C } from './dep';\nlet c: C | undefined;\nconsole.log('main', c === undefined);",
    expected: 'main true\n',
  },
  'value in a type alias only': {
    'dep.ts': "export const E = { A: 1 } as const;\nconsole.log('dep');",
    'entry.ts': "import { E } from './dep';\nexport type X = typeof E;\nconsole.log('main');",
    expected: 'main\n',
  },
  'unused import of a top-level-await module': {
    'dep.ts': "export const v = 1;\nconsole.log('dep', await Promise.resolve(2));",
    'entry.ts': "import { v } from './dep';\nconsole.log('main');",
    expected: 'main\n',
  },
  'type from a package that is not installed': {
    'entry.ts':
      "import { Foo } from 'types-only-not-installed';\nconst x: Foo | null = null;\nconsole.log('main', x);",
    expected: 'main null\n',
  },
  // Kept: a value use, and an import mixing a value with a type.
  'value import is kept': {
    'dep.ts': "export const v = 1;\nconsole.log('dep');",
    'entry.ts': "import { v } from './dep';\nconsole.log('main', v);",
    expected: 'dep\nmain 1\n',
  },
  'import mixing a type and a value is kept': {
    'dep.ts': "export interface T { n: number }\nexport const v = 1;\nconsole.log('dep');",
    'entry.ts': "import { T, v } from './dep';\nconst t: T = { n: v };\nconsole.log('main', t.n);",
    expected: 'dep\nmain 1\n',
  },
} as const;

describe('TypeScript type-only imports do not evaluate their module (#5581)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const target of ['es2019', 'es2022']) {
    for (const [name, { expected, ...files }] of Object.entries(cases)) {
      test(`${name}, ${target}`, async () => {
        const created = await createFixture({ ...files, 'package.json': '{"type":"module"}' });
        cleanup = created.cleanup;
        const out = join(created.dir, 'out.mjs');
        const result = await runZntc([
          '--bundle',
          join(created.dir, 'entry.ts'),
          '--format=esm',
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
});
