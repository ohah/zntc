import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createFixture, runZntc } from './helpers';

// #5594: an exported `const enum` lost its declaration, so another module's
// `E.B` was a ReferenceError. tsc --isolatedModules (preserveConstEnums
// implied) and esbuild's transform keep the declaration as a regular enum;
// esbuild and rolldown bundles print the same values as below.
const cases = {
  'exported const enum read by another module': {
    'dep.ts': "export const enum E { A = 1, B = 2 }\nconsole.log('dep');",
    'entry.ts': "import { E } from './dep';\nconsole.log('main', E.B);",
    expected: 'dep\nmain 2\n',
  },
  'const enum exported with export {}': {
    'dep.ts': "const enum E { A = 'a', B = 'b' }\nexport { E };\nconsole.log('dep', E.A);",
    'entry.ts': "import { E } from './dep';\nconsole.log('main', E.B);",
    expected: 'dep a\nmain b\n',
  },
  'const enum member read by computed key': {
    'dep.ts': "export const enum E { A = 1 << 2, B = A | 1 }\nconsole.log('dep');",
    'entry.ts': "import { E } from './dep';\nconsole.log('main', E['B'], E.A);",
    expected: 'dep\nmain 5 4\n',
  },
} as const;

describe('exported const enum keeps its declaration (#5594)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const format of ['esm', 'cjs']) {
    for (const [name, { expected, ...files }] of Object.entries(cases)) {
      test(`${name}, ${format}`, async () => {
        const created = await createFixture(files);
        cleanup = created.cleanup;
        const out = join(created.dir, format === 'esm' ? 'out.mjs' : 'out.cjs');
        const result = await runZntc([
          '--bundle',
          join(created.dir, 'entry.ts'),
          `--format=${format}`,
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

  test('transform keeps an exported const enum and inlines local uses', async () => {
    const created = await createFixture({
      'enums.ts':
        'export const enum E { A = 1, B = 2 }\nconst enum L { X = 3 }\nexport const sum = E.A + L.X;',
    });
    cleanup = created.cleanup;
    const out = join(created.dir, 'enums.mjs');
    const result = await runZntc([join(created.dir, 'enums.ts'), '-o', out]);
    expect(result.exitCode, result.stderr).toBe(0);
    const code = await readFile(out, 'utf8');
    // Local const enum: declaration dropped, use inlined.
    expect(code).not.toContain('var L');
    const run = spawnSync(
      'node',
      [
        '--input-type=module',
        '-e',
        `const m = await import(${JSON.stringify(pathToFileURL(out).href)}); console.log(m.E.B, m.E[2], m.sum);`,
      ],
      { encoding: 'utf8' },
    );
    expect(run.status, run.stderr).toBe(0);
    expect(run.stdout).toBe('2 B 4\n');
  });

  test('a local const enum is still dropped in a bundle', async () => {
    const created = await createFixture({
      'entry.ts': "const enum L { X = 3 }\nconsole.log('main', L.X);",
    });
    cleanup = created.cleanup;
    const out = join(created.dir, 'out.mjs');
    const result = await runZntc([
      '--bundle',
      join(created.dir, 'entry.ts'),
      '--format=esm',
      '-o',
      out,
    ]);
    expect(result.exitCode, result.stderr).toBe(0);
    expect(await readFile(out, 'utf8')).not.toContain('L.X');
    const run = spawnSync('node', [out], { encoding: 'utf8' });
    expect(run.stdout).toBe('main 3\n');
  });
});
