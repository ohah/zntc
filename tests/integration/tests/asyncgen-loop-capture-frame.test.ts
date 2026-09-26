import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntcInDir } from './helpers';

const cases = [
  {
    name: 'arrow captures source arguments and this',
    body: 'yield (() => this.base + arguments.length + item)();',
  },
  {
    name: 'direct arguments beside a captured closure',
    body: 'yield arguments.length + (() => item)();',
  },
  {
    name: 'nested extracted loops share source arguments',
    body: 'for await (const nested of [item]) { yield (() => this.base + arguments.length + nested)(); }',
  },
  {
    name: 'real nested function keeps its own arguments',
    body: 'function own(a, b) { return arguments.length; } yield own(1, 2) + (() => item)();',
  },
  {
    name: 'real nested generator keeps its own arguments',
    body: 'function* own(a, b) { yield arguments.length; } yield own(1, 2).next().value + (() => item)();',
  },
] as const;

describe('async generator extracted loop lexical captures (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const fixture of cases) {
    for (const target of ['es5', 'es2015'] as const) {
      for (const bundle of [false, true]) {
        for (const minify of [false, true]) {
          test(`${fixture.name}, ${target}, ${bundle ? 'bundle' : 'single'}, ${minify ? 'minify' : 'plain'}`, async () => {
            const source = `async function* collect(items) {
              for await (const item of items) { ${fixture.body} }
            }
            async function main() {
              const values = [];
              for await (const value of collect.call({ base: 2 }, [1])) values.push(value);
              console.log(values.join(','));
            }
            main();`;
            const dir = await createFixture({
              'input.mjs': source,
              'package.json': '{"type":"module"}',
            });
            cleanup = dir.cleanup;
            const native = spawnSync('node', [join(dir.dir, 'input.mjs')], { encoding: 'utf8' });
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

  const syncSource = `function* collect(items) {
    for (let i = 0; i < items.length; i++) {
      yield (() => this.base + arguments.length + i)();
    }
  }
  console.log([...collect.call({ base: 2 }, [1])].join(','));`;
  for (const target of ['es5', 'es2015'] as const) {
    for (const bundle of [false, true]) {
      for (const minify of [false, true]) {
        test(`sync generator extracted loop, ${target}, ${bundle ? 'bundle' : 'single'}, ${minify ? 'minify' : 'plain'}`, async () => {
          const dir = await createFixture({
            'input.mjs': syncSource,
            'package.json': '{"type":"module"}',
          });
          cleanup = dir.cleanup;
          const native = spawnSync('node', [join(dir.dir, 'input.mjs')], { encoding: 'utf8' });
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
});
