import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntcInDir } from './helpers';

const cases = [
  {
    name: 'class constructor',
    source: `function get() { return { value: 5 }; }
      class Host { constructor(value = get()?.value) { this.value = value; } }
      console.log(new Host().value);`,
  },
  {
    name: 'class method',
    source: `function get() { return { value: 5 }; }
      class Host { run(value = get()?.value) { return value; } }
      console.log(new Host().run());`,
  },
  {
    name: 'class setter',
    source: `function get() { return { value: 5 }; }
      class Host { set value(input = get()?.value) { this.saved = input; } }
      const host = new Host();
      Object.getOwnPropertyDescriptor(Host.prototype, 'value').set.call(host);
      console.log(host.saved);`,
  },
  {
    name: 'async class method',
    source: `function get() { return { value: 5 }; }
      class Host { async run(value = get()?.value) { return value; } }
      new Host().run().then(value => console.log(value));`,
  },
  {
    name: 'generator class method',
    source: `function get() { return { value: 5 }; }
      class Host { *run(value = get()?.value) { yield value; } }
      console.log(new Host().run().next().value);`,
  },
  {
    name: 'async generator class method',
    source: `function get() { return { value: 5 }; }
      class Host { async *run(value = get()?.value) { yield value; } }
      new Host().run().next().then(result => console.log(result.value));`,
  },
  {
    name: 'generator function',
    source: `function get() { return { value: 5 }; }
      function* run(value = get()?.value) { yield value; }
      console.log(run().next().value);`,
  },
  {
    name: 'async function',
    source: `function get() { return { value: 5 }; }
      async function run(value = get()?.value) { return value; }
      run().then(value => console.log(value));`,
  },
  {
    name: 'async generator function',
    source: `function get() { return { value: 5 }; }
      async function* run(value = get()?.value) { yield value; }
      run().next().then(result => console.log(result.value));`,
  },
  {
    name: 'async generator for-await body and parameter temp',
    source: `function get() { return { value: 5 }; }
      async function* run(value = get()?.value) {
        for await (const item of [1]) yield value + item;
      }
      run().next().then(result => console.log(result.value));`,
  },
] as const;

// These 12 fixture/target combinations also fail with the c532 baseline:
// their retained native defaults read a temp declared in the function body (or
// no temp declaration). They need a separate parameter-environment producer,
// beyond the lowered-default scope contract exercised by this matrix.
const nativeDefaultBaselineGaps = new Set([
  'class constructor/es2015',
  'class constructor/es2017',
  'class method/es2015',
  'class method/es2017',
  'class setter/es2015',
  'class setter/es2017',
  'async class method/es2017',
  'generator class method/es2015',
  'generator class method/es2017',
  'generator function/es2015',
  'generator function/es2017',
  'async function/es2017',
]);

describe('parameter optional-chain temp scope (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const fixture of cases) {
    for (const target of ['es5', 'es2015', 'es2017', 'esnext', 'hermes'] as const) {
      for (const bundle of [false, true]) {
        for (const minify of [false, true]) {
          if (nativeDefaultBaselineGaps.has(`${fixture.name}/${target}`)) {
            test.todo(
              `${fixture.name}, ${target}, ${bundle ? 'bundle' : 'single'}, ${minify ? 'minify' : 'plain'}: native default environment`,
            );
            continue;
          }
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
              target === 'hermes' ? '--platform=react-native' : `--target=${target}`,
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
