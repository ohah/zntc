import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';
const cli = process.env.ZNTC_USING_PURITY_CLI ?? ZNTC_BIN;
const initializers = [
  '42',
  "'value'",
  'true',
  '1n',
  '/value/',
  '[]',
  '{}',
  '()=>{}',
  'class {}',
  'true?{}:[]',
];
describe('native using has cleanup effects independent of its initializer (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });
  for (const [index, initializer] of initializers.entries())
    for (const minify of [false, true]) {
      test(`${index}: ${minify ? 'minified' : 'plain'} invalid resource still throws`, async () => {
        const fixture = await createFixture({
          'input.cjs': `using resource=${initializer};console.log('after');`,
        });
        cleanup = fixture.cleanup;
        const input = join(fixture.dir, 'input.cjs');
        const output = join(fixture.dir, 'output.cjs');
        const native = spawnSync('node', [input], { encoding: 'utf8' });
        expect(native.status).not.toBe(0);
        expect(native.stderr).toContain('TypeError');
        const built = spawnSync(
          cli,
          [
            input,
            '--target=esnext',
            '--bundle',
            '--platform=node',
            '--format=cjs',
            ...(minify ? ['--minify'] : []),
            '-o',
            output,
          ],
          { encoding: 'utf8' },
        );
        expect(built.status, built.stderr).toBe(0);
        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, actual.stderr).toBe(native.status);
        expect(actual.stderr).toContain('TypeError');
        expect(actual.stdout).toBe(native.stdout);
      });
    }
  for (const minify of [false, true]) {
    test(`unused valid resource disposes: ${minify ? 'minified' : 'plain'}`, async () => {
      const fixture = await createFixture({
        'input.cjs':
          'const events=[];using resource={[Symbol.dispose](){events.push("dispose")}};setTimeout(()=>console.log(JSON.stringify(events)),0);',
      });
      cleanup = fixture.cleanup;
      const input = join(fixture.dir, 'input.cjs');
      const output = join(fixture.dir, 'output.cjs');
      const native = spawnSync('node', [input], { encoding: 'utf8' });
      expect(native.status, native.stderr).toBe(0);
      const built = spawnSync(
        cli,
        [
          input,
          '--target=esnext',
          '--bundle',
          '--platform=node',
          '--format=cjs',
          ...(minify ? ['--minify'] : []),
          '-o',
          output,
        ],
        { encoding: 'utf8' },
      );
      expect(built.status, built.stderr).toBe(0);
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe(native.stdout);
    });
  }
});
