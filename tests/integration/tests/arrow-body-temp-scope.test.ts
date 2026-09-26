import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntcInDir } from './helpers';

const cases = [
  {
    name: 'arrow expression body',
    targets: ['es5', 'es2015', 'es2017'],
    source: `function get() { return { value: 5 }; }
      const read = () => get()?.value;
      console.log(read());`,
  },
  {
    name: 'arrow inside async state callback',
    targets: ['es5', 'es2015', 'es2017'],
    source: `function get() { return { value: 5 }; }
      async function outer() { await 0; return (() => get()?.value)(); }
      outer().then(value => console.log(value));`,
  },
  {
    name: 'arrow body in function parameter default',
    targets: ['es5', 'es2015', 'es2017'],
    source: `function get() { return { value: 5 }; }
      function run(value = (() => get()?.value)()) { return value; }
      console.log(run());`,
  },
] as const;

describe('arrow body temp scope (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const fixture of cases) {
    for (const target of fixture.targets) {
      for (const bundle of [false, true]) {
        for (const minify of [false, true]) {
          test(`${fixture.name}, ${target}, ${bundle ? 'bundle' : 'single'}, ${minify ? 'minify' : 'plain'}`, async () => {
            const dir = await createFixture({
              'input.mjs': fixture.source,
              'package.json': '{"type":"module"}',
            });
            cleanup = dir.cleanup;
            const input = join(dir.dir, 'input.mjs');
            const native = spawnSync('node', [input], { encoding: 'utf8' });
            expect(native.status, native.stderr).toBe(0);
            const output = join(dir.dir, bundle ? 'out.cjs' : 'out.mjs');
            const result = await runZntcInDir(dir.dir, [
              ...(bundle ? ['--bundle', '--platform=node', '--format=cjs'] : []),
              'input.mjs',
              `--target=${target}`,
              ...(minify ? ['--minify'] : []),
              '-o',
              output,
            ]);
            expect(result.exitCode, result.stderr).toBe(0);
            const actual = spawnSync('node', [output], { encoding: 'utf8' });
            expect(actual.status, actual.stderr).toBe(0);
            expect(actual.stdout).toBe(native.stdout);
          });
        }
      }
    }
  }
});
