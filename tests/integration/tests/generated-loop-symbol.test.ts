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

      test(`${bundled ? 'bundle' : 'single-file'} generator for-in keeps same-name temps in separate scopes (${minify ? 'minify' : 'plain'})`, async () => {
        const fixture = await createFixture({
          'input.mjs': `
const _a = 10, _b = 20, _keys = 30, _idx = 40;
function* first(source) {
  for (const key in source) yield () => key + ':' + _a + ':' + _b + ':' + _keys + ':' + _idx;
}
function* second(source) {
  for (const key in source) yield () => key + ':' + _a + ':' + _b + ':' + _keys + ':' + _idx;
}
console.log([...first({ x: 0, y: 0 }), ...second({ p: 0, q: 0 })].map(read => read()).join(','));
`,
        });
        cleanup = fixture.cleanup;
        const input = join(fixture.dir, 'input.mjs');
        const native = spawnSync('node', [input], { encoding: 'utf8' });
        expect(native.status, native.stderr).toBe(0);
        const output = join(fixture.dir, bundled ? 'out.cjs' : 'out.mjs');
        const result = await runZntcInDir(fixture.dir, [
          ...(bundled ? ['--bundle'] : []),
          'input.mjs',
          '--target=es5',
          ...(minify ? ['--minify-identifiers', '--minify-syntax'] : []),
          ...(bundled ? ['--platform=node', '--format=cjs'] : []),
          '-o',
          output,
        ]);
        expect(result.exitCode, result.stderr).toBe(0);
        const runtime = spawnSync('node', [output], { encoding: 'utf8' });
        expect(runtime.status, runtime.stderr).toBe(0);
        expect(runtime.stdout).toBe(native.stdout);
      });

      test(`${bundled ? 'bundle' : 'single-file'} generator for-of keeps same-name temps in separate scopes (${minify ? 'minify' : 'plain'})`, async () => {
        const fixture = await createFixture({
          'input.mjs': `
const _a = 10, _b = 20, _c = 30, _d = 40, _step = 50;
function* first(source) {
  for (const value of source) yield () => value + ':' + _a + ':' + _b + ':' + _c + ':' + _d + ':' + _step;
}
function* second(source) {
  for (const value of source) yield () => value + ':' + _a + ':' + _b + ':' + _c + ':' + _d + ':' + _step;
}
console.log([...first([1, 2]), ...second([3, 4])].map(read => read()).join(','));
`,
        });
        cleanup = fixture.cleanup;
        const input = join(fixture.dir, 'input.mjs');
        const native = spawnSync('node', [input], { encoding: 'utf8' });
        expect(native.status, native.stderr).toBe(0);
        const output = join(fixture.dir, bundled ? 'out.cjs' : 'out.mjs');
        const result = await runZntcInDir(fixture.dir, [
          ...(bundled ? ['--bundle'] : []),
          'input.mjs',
          '--target=es5',
          ...(minify ? ['--minify-identifiers', '--minify-syntax'] : []),
          ...(bundled ? ['--platform=node', '--format=cjs'] : []),
          '-o',
          output,
        ]);
        expect(result.exitCode, result.stderr).toBe(0);
        const runtime = spawnSync('node', [output], { encoding: 'utf8' });
        expect(runtime.status, runtime.stderr).toBe(0);
        expect(runtime.stdout).toBe(native.stdout);
      });
    }
  }
});
