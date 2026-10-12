import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5564: bundling lowers top-level await into an async wrapper. An export
// declaration initialized by `await` needs native async functions to defer
// the export; without them the await was lowered to a top-level `yield`
// (SyntaxError at runtime). Such a build now fails with ZNTC0001, like
// transpile does, while other top-level await still lowers.
describe('top-level await in export declarations without async (#5564)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  async function bundle(files: Record<string, string>, entry: string, target: string) {
    const created = await createFixture(files);
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
    return { result, out };
  }

  const rejected = {
    'export const': 'export const v = await Promise.resolve(1);\nconsole.log(v);',
    'export default': 'export default await Promise.resolve(1);',
    'export let destructuring':
      'export let { v } = await Promise.resolve({ v: 1 });\nconsole.log(v);',
  } as const;

  for (const target of ['es2016', 'es5']) {
    for (const [name, source] of Object.entries(rejected)) {
      test(`${name} is rejected with ZNTC0001, ${target}`, async () => {
        const { result } = await bundle({ 'entry.mjs': source }, 'entry.mjs', target);
        expect(result.exitCode).not.toBe(0);
        expect(result.stderr).toContain('ZNTC0001');
        expect(result.stderr).toContain('Top-level await in an export declaration');
      });
    }

    test(`an exported dependency is rejected too, ${target}`, async () => {
      const { result } = await bundle(
        {
          'dep.mjs': 'export const v = await Promise.resolve(1);',
          'entry.mjs': "import { v } from './dep.mjs';\nconsole.log(v);",
        },
        'entry.mjs',
        target,
      );
      expect(result.exitCode).not.toBe(0);
      expect(result.stderr).toContain('ZNTC0001');
    });

    // Statements (not export declarations) still lower into the wrapper.
    test(`plain top-level await still lowers, ${target}`, async () => {
      const { result, out } = await bundle(
        {
          'entry.mjs':
            'export const k = 1;\nconst f = async () => await 2;\nconsole.log(await f(), k);',
        },
        'entry.mjs',
        target,
      );
      expect(result.exitCode, result.stderr).toBe(0);
      const run = spawnSync('node', [out], { encoding: 'utf8' });
      expect(run.status, run.stderr).toBe(0);
      expect(run.stdout).toBe('2 1\n');
    });
  }

  // Targets with async functions defer the export as before.
  test('es2017 still defers the exported await', async () => {
    const { result, out } = await bundle(
      { 'entry.mjs': 'export const v = await Promise.resolve(1);\nconsole.log(v);' },
      'entry.mjs',
      'es2017',
    );
    expect(result.exitCode, result.stderr).toBe(0);
    const run = spawnSync('node', [out], { encoding: 'utf8' });
    expect(run.status, run.stderr).toBe(0);
    expect(run.stdout).toBe('1\n');
  });
});
