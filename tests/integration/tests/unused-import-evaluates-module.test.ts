import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5571: a JS import evaluates its module even when the binding is unused or
// was inlined. The linker applied TypeScript's type-only import elision to JS
// too, so a wrapped dependency (async `__esm` for top-level await, or
// `__commonJS`) never ran its init: `import { v } from './dep'` with `v`
// inlined as a constant dropped dep's side effects. TypeScript still elides an
// import used only as a type, judged on the source (esbuild/rolldown match).
const cases = {
  'JS: inlined export of a top-level-await module': {
    'dep.mjs': "export const v = 1;\nconsole.log('dep', await Promise.resolve(2));",
    'entry.mjs': "import { v } from './dep.mjs';\nconsole.log('main', v);",
  },
  'JS: unused import of a top-level-await module': {
    'dep.mjs': "export const v = { n: 1 };\nconsole.log('dep', await Promise.resolve(2));",
    'entry.mjs': "import { v } from './dep.mjs';\nconsole.log('main');",
  },
  'JS: unused import of a CommonJS module': {
    'dep.cjs': "console.log('cjs dep');\nexports.v = 1;",
    'entry.mjs': "import { v } from './dep.cjs';\nconsole.log('main');",
  },
} as const;

// TypeScript sources (node cannot run them): the expected output is fixed.
const tsCases = {
  'TS: inlined value import of a top-level-await module': {
    files: {
      'dep.ts': "export const v = 1;\nconsole.log('dep', await Promise.resolve(2));",
      'entry.ts': "import { v } from './dep';\nconsole.log('main', v);",
    },
    expected: 'dep 2\nmain 1\n',
  },
  'TS: value import of a CommonJS module': {
    files: {
      'dep.cjs': "console.log('cjs dep');\nexports.v = 1;",
      'entry.ts': "import { v } from './dep.cjs';\nconsole.log('main', v);",
    },
    expected: 'cjs dep\nmain 1\n',
  },
} as const;

describe('an import evaluates its module (#5571)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  async function bundle(files: Record<string, string>, entry: string, target: string) {
    const created = await createFixture({ ...files, 'package.json': '{"type":"module"}' });
    cleanup = created.cleanup;
    const out = join(created.dir, 'out.mjs');
    const result = await runZntc([
      '--bundle',
      join(created.dir, entry),
      '--format=esm',
      `--target=${target}`,
      '-o',
      out,
    ]);
    expect(result.exitCode, result.stderr).toBe(0);
    const run = spawnSync('node', [out], { encoding: 'utf8' });
    expect(run.status, run.stderr).toBe(0);
    return { dir: created.dir, stdout: run.stdout };
  }

  for (const target of ['es2019', 'es2022']) {
    for (const [name, files] of Object.entries(cases)) {
      test(`${name}, ${target}`, async () => {
        const { dir, stdout } = await bundle(files, 'entry.mjs', target);
        const native = spawnSync('node', [join(dir, 'entry.mjs')], { encoding: 'utf8' });
        expect(native.status, native.stderr).toBe(0);
        expect(stdout).toBe(native.stdout);
      });
    }

    for (const [name, { files, expected }] of Object.entries(tsCases)) {
      test(`${name}, ${target}`, async () => {
        const { stdout } = await bundle(files, 'entry.ts', target);
        expect(stdout).toBe(expected);
      });
    }

    // TypeScript elides an import used only as a type: the module is not
    // evaluated for it (tsc, esbuild and rolldown agree).
    test(`TS: type-only import stays elided, ${target}`, async () => {
      const { stdout } = await bundle(
        {
          'dep.cjs': "console.log('cjs dep');\nexports.v = 1;",
          'types.ts': 'export interface Shape { n: number }',
          'entry.ts':
            "import { v } from './dep.cjs';\nimport { Shape } from './types';\nconst s: Shape = { n: 1 };\nlet t: typeof v;\nconsole.log('main', s.n);",
        },
        'entry.ts',
        target,
      );
      expect(stdout).toBe('main 1\n');
    });
  }
});
