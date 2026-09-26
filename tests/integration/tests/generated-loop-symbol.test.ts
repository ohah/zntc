import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntcInDir } from './helpers';

describe('generated _loop symbol identity (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const bundled of [false, true]) {
    test(`${bundled ? 'bundle' : 'single-file'} preserves colliding user bindings under minify`, async () => {
      const fixture = await createFixture({
        'input.mjs': `
const _loop = 7;
const _loop2 = 100;
const _loop3 = 200;
const getters = [];
for (let i = 0; i < 3; i++) getters.push(() => i + _loop);
for (let j = 0; j < 3; j++) getters.push(() => j + _loop2);
console.log(getters.map(f => f()).join(','), _loop2, _loop3);
`,
      });
      cleanup = fixture.cleanup;
      const out = join(fixture.dir, 'out.cjs');
      const args = [
        ...(bundled ? ['--bundle'] : []),
        'input.mjs',
        '--target=es5',
        '--minify-identifiers',
        '--minify-syntax',
        ...(bundled ? ['--platform=node', '--format=cjs'] : []),
        '-o',
        out,
      ];
      const result = await runZntcInDir(fixture.dir, args);
      expect(result.exitCode).toBe(0);
      const runtime = spawnSync('node', [out], { encoding: 'utf8' });
      expect(runtime.status).toBe(0);
      expect(runtime.stdout.trim()).toBe('7,8,9,100,101,102 100 200');
    });

    for (const minify of [false, true]) {
      test(`${bundled ? 'bundle' : 'single-file'} generator keeps header captures (${minify ? 'minify' : 'plain'})`, async () => {
        const fixture = await createFixture({
          'input.mjs': `
const _loop = 7;
function* collect(index) {
  for (let index = 0, offset = 10; index < 3; index++, offset--) {
    yield () => index * offset + _loop;
  }
  yield () => index;
}
console.log([...collect(100)].map(read => read()).join(','));
`,
        });
        cleanup = fixture.cleanup;
        const native = spawnSync('node', [join(fixture.dir, 'input.mjs')], { encoding: 'utf8' });
        expect(native.status).toBe(0);
        expect(native.stdout.trim()).toBe('7,16,23,100');
        const out = join(fixture.dir, 'out.cjs');
        const result = await runZntcInDir(fixture.dir, [
          ...(bundled ? ['--bundle'] : []),
          'input.mjs',
          '--target=es5',
          ...(minify ? ['--minify-identifiers', '--minify-syntax'] : []),
          ...(bundled ? ['--platform=node', '--format=cjs'] : []),
          '-o',
          out,
        ]);
        expect(result.exitCode).toBe(0);
        const runtime = spawnSync('node', [out], { encoding: 'utf8' });
        expect(runtime.status).toBe(0);
        expect(runtime.stdout).toBe(native.stdout);
      });
    }
  }
});
