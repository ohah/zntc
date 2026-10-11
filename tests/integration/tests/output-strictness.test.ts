import { afterEach, describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createFixture, runNode, runZntc } from './helpers';

// #5455: the output's strictness must match the bundled modules. A file-level
// "use strict" for cjs output would turn a sloppy CommonJS dependency strict
// (esbuild/rolldown never force it), and ESM output cannot contain `with`
// (esbuild reports the same build error).
describe('bundle output strictness (#5455)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  test('cjs output keeps a sloppy CommonJS dependency sloppy', async () => {
    const fixture = await createFixture({
      'dep.cjs': 'with ({ v: 1 }) { module.exports = v; }',
      'entry.mjs': "import v from './dep.cjs'; console.log(v);",
    });
    cleanup = fixture.cleanup;
    const out = join(fixture.dir, 'out.cjs');
    const result = await runZntc([
      '--bundle',
      join(fixture.dir, 'entry.mjs'),
      '--format=cjs',
      '-o',
      out,
    ]);
    expect(result.exitCode, result.stderr).toBe(0);
    expect(readFileSync(out, 'utf8').startsWith('"use strict"')).toBe(false);
    expect((await runNode(out)).stdout.trim()).toBe('1');
  });

  test('cjs output of only strict modules keeps the directive', async () => {
    const fixture = await createFixture({
      'a.mjs': 'export const f = function () { return this === undefined; };',
      'entry.mjs': "import { f } from './a.mjs'; console.log(f());",
    });
    cleanup = fixture.cleanup;
    const out = join(fixture.dir, 'out.cjs');
    const result = await runZntc([
      '--bundle',
      join(fixture.dir, 'entry.mjs'),
      '--format=cjs',
      '-o',
      out,
    ]);
    expect(result.exitCode, result.stderr).toBe(0);
    expect(readFileSync(out, 'utf8').startsWith('"use strict"')).toBe(true);
    expect((await runNode(out)).stdout.trim()).toBe('true');
  });

  test('esm output warns about a with statement', async () => {
    const fixture = await createFixture({
      'dep.cjs': 'with ({ v: 1 }) { module.exports = v; }',
      'entry.mjs': "import v from './dep.cjs'; console.log(v);",
    });
    cleanup = fixture.cleanup;
    const result = await runZntc([
      '--bundle',
      join(fixture.dir, 'entry.mjs'),
      '--format=esm',
      '-o',
      join(fixture.dir, 'out.mjs'),
    ]);
    expect(result.exitCode, result.stderr).toBe(0);
    expect(result.stderr).toContain('ZNTC0800');
    expect(result.stderr).toContain('With statements cannot be used with the "esm" output format');
  });
});
