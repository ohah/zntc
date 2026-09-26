import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntcInDir } from './helpers';

describe('generated temp allocation identity (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const bundled of [false, true]) {
    test(`${bundled ? 'bundle' : 'single-file'} keeps nested temp variables distinct`, async () => {
      const fixture = await createFixture({
        'input.mjs': `
const _a = 40;
function outer(value) {
  const _b = 2;
  function inner(input) { return (input ?? _b) + _a; }
  return inner(value) + (value ?? 3);
}
console.log(outer(null), outer(1));
`,
      });
      cleanup = fixture.cleanup;
      const out = join(fixture.dir, 'out.cjs');
      const result = await runZntcInDir(fixture.dir, [
        ...(bundled ? ['--bundle'] : []),
        'input.mjs',
        '--target=es5',
        '--minify-identifiers',
        '--minify-syntax',
        ...(bundled ? ['--platform=node', '--format=cjs'] : []),
        '-o',
        out,
      ]);
      expect(result.exitCode).toBe(0);
      const runtime = spawnSync('node', [out], { encoding: 'utf8' });
      expect(runtime.status).toBe(0);
      expect(runtime.stdout.trim()).toBe('45 42');
    });
  }
});
