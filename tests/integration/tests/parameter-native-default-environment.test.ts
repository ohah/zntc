import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntcInDir } from './helpers';

// ES2017 keeps default syntax but lowers optional chaining and async generators.
// These defaults must still execute before the body, in the native parameter
// environment. The direct-eval case uses a sloppy CommonJS script without a
// bundler wrapper so eval can declare a name for the following parameter.
const cases = [
  {
    name: 'body var shadow',
    source: `let outside = 5;
      function get() { return { value: 2 }; }
      async function* run(value = get()?.value + outside) {
        var outside = 20;
        yield value;
      }
      run().next().then(result => console.log(result.value));`,
  },
  {
    name: 'body function shadow',
    source: `function outside() { return 5; }
      function get() { return { value: 2 }; }
      async function* run(value = get()?.value + outside()) {
        function outside() { return 20; }
        yield value;
      }
      run().next().then(result => console.log(result.value));`,
  },
  {
    name: 'later parameter TDZ',
    source: `function get() { return { value: 2 }; }
      async function* run(value = get()?.value + later, later = 2) { yield value; }
      try { run(); } catch (error) { console.log(error.name); }`,
  },
  {
    name: 'parameter closure ignores body shadow',
    source: `let outside = 5;
      function get() { return { value: 2 }; }
      async function* run(value = (get()?.value, () => outside)) {
        var outside = 20;
        yield value();
      }
      run().next().then(result => console.log(result.value));`,
  },
  {
    name: 'sloppy direct eval reaches later parameter',
    source: `function get() { return { value: 2 }; }
      async function* run(
        value = (eval('var injected = 7'), get()?.value),
        seen = typeof injected,
      ) {
        var injected = 99;
        yield [value, seen];
      }
      run().next().then(result => console.log(JSON.stringify(result.value)));`,
    singleOnly: true,
  },
] as const;

describe('native default parameter environment with generated temps (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const fixture of cases) {
    for (const bundle of [false, true]) {
      if ('singleOnly' in fixture && fixture.singleOnly && bundle) continue;
      for (const minify of [false, true]) {
        test(`${fixture.name}, ${bundle ? 'bundle' : 'single'}, ${minify ? 'minify' : 'plain'}`, async () => {
          const dir = await createFixture({ 'input.cjs': fixture.source });
          cleanup = dir.cleanup;
          const input = join(dir.dir, 'input.cjs');
          const native = spawnSync('node', [input], { encoding: 'utf8' });
          expect(native.status, native.stderr).toBe(0);
          const output = join(dir.dir, 'out.cjs');
          const result = await runZntcInDir(dir.dir, [
            ...(bundle ? ['--bundle', '--platform=node', '--format=cjs'] : []),
            'input.cjs',
            '--target=es2017',
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
