import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createFixture, runZntc } from './helpers';

// #5583: re-exporting a TypeScript type (`export { T }` of an imported type,
// `export { T } from`) is elided by tsc and esbuild. The bundler failed the
// build (ZNTC0101 missing export) or emitted a dangling `export { T }`, a
// SyntaxError at load. Each case prints the entry's log lines and then its
// export names; esbuild 0.27.7 gives the expected output for every case.
const dep =
  "export interface T { n: number }\nexport type U = string;\nexport const v = 1;\nconsole.log('dep');";

const cases = {
  'imported type re-exported with export {}': {
    'entry.ts': "import { T } from './dep';\nexport { T };\nconsole.log('main');",
    expected: 'dep\nmain\n\n',
  },
  'export {} from of a type': {
    'entry.ts': "export { T } from './dep';\nconsole.log('main');",
    expected: 'dep\nmain\n\n',
  },
  'type alias re-exported': {
    'entry.ts': "export { U } from './dep';\nconsole.log('main');",
    expected: 'dep\nmain\n\n',
  },
  'imported type and value re-exported together': {
    'entry.ts': "import { T, v } from './dep';\nexport { T, v };\nconsole.log('main', v);",
    expected: 'dep\nmain 1\nv\n',
  },
  'renamed type re-export beside a value': {
    'entry.ts': "export { T as Renamed, v } from './dep';\nconsole.log('main');",
    expected: 'dep\nmain\nv\n',
  },
  'type re-exported through a barrel': {
    'barrel.ts': "export { T, v } from './dep';",
    'entry.ts': "export { T as X, v } from './barrel';\nconsole.log('main');",
    expected: 'dep\nmain\nv\n',
  },
  'local type exported under another name': {
    'entry.ts':
      "interface L { n: number }\nexport { L as M };\nexport const w = 2;\nconsole.log('main');",
    expected: 'main\nw\n',
  },
  'declared value re-exported': {
    'ambient.ts':
      "export declare const g: number;\nexport declare function f(): void;\nexport const h = 2;\nconsole.log('ambient');",
    'entry.ts': "export { g, f, h } from './ambient';\nconsole.log('main');",
    expected: 'ambient\nmain\nh\n',
  },
  'export * from a module with types': {
    'entry.ts': "export * from './dep';\nconsole.log('main');",
    expected: 'dep\nmain\nv\n',
  },
  // Kept: an interface merged with a value of the same name is a value.
  'interface merged with a value is kept': {
    'dep.ts': "export interface C { n: number }\nexport const C = 3;\nconsole.log('dep');",
    'entry.ts': "export { C } from './dep';\nconsole.log('main');",
    expected: 'dep\nmain\nC\n',
  },
} as const;

describe('TypeScript type re-exports are elided (#5583)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const format of ['esm', 'cjs']) {
    for (const [name, { expected, ...files }] of Object.entries(cases)) {
      test(`${name}, ${format}`, async () => {
        const created = await createFixture({ 'dep.ts': dep, ...files });
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
        const run = spawnSync(
          'node',
          [
            '--input-type=module',
            '-e',
            `const m = await import(${JSON.stringify(pathToFileURL(out).href)});` +
              "console.log(Object.keys(m).filter((k) => k !== 'default' && k !== 'module.exports').join(','));",
          ],
          { encoding: 'utf8' },
        );
        expect(run.status, run.stderr).toBe(0);
        expect(run.stdout).toBe(expected);
      });
    }
  }

  test('namespace import of a module re-exporting a type', async () => {
    const created = await createFixture({
      'dep.ts': dep,
      'mid.ts': "export { T as Renamed, v } from './dep';",
      'entry.ts': "import * as ns from './mid';\nconsole.log(Object.keys(ns).join(','));",
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
    const run = spawnSync('node', [out], { encoding: 'utf8' });
    expect(run.status, run.stderr).toBe(0);
    expect(run.stdout).toBe('dep\nv\n');
  });
});
