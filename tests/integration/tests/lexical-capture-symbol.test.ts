import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntcInDir } from './helpers';

const cases = [
  {
    name: 'nested function frames and user alias names',
    target: 'es5',
    source: `function outer(_this, _arguments) {
      const first = () => this.base + arguments[0];
      function inner() { return () => this.base + arguments[0]; }
      return [first(), inner.call({ base: 5 }, 7)()];
    }
    console.log(outer.call({ base: 2 }, 3).join(','));`,
  },
  {
    name: 'class method parameter capture',
    target: 'es5',
    source: `class C {
      constructor(base) { this.base = base; }
      method(value = (() => this.base + arguments.length)()) { return value; }
    }
    console.log(new C(2).method());`,
  },
  {
    name: 'class method body capture',
    target: 'es5',
    source: `class C {
      constructor(base) { this.base = base; }
      method(value) { return (() => this.base + arguments[0])(); }
    }
    console.log(new C(2).method(3));`,
  },
  {
    name: 'async body capture',
    target: 'es5',
    source: `async function run(value) {
      await 0;
      return (() => this.base + arguments[0])();
    }
    run.call({ base: 2 }, 3).then(value => console.log(value));`,
  },
  {
    name: 'async body capture with kept arrow',
    target: 'es2015',
    source: `async function run(value) {
      await 0;
      return (() => this.base + arguments[0])();
    }
    run.call({ base: 2 }, 3).then(value => console.log(value));`,
  },
  {
    name: 'generator body capture',
    target: 'es5',
    source: `function* run(value) {
      yield (() => this.base + arguments[0])();
    }
    console.log(run.call({ base: 2 }, 3).next().value);`,
  },
] as const;

describe('lexical capture symbol frames (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const fixture of cases) {
    for (const bundle of [false, true]) {
      for (const minify of [false, true]) {
        test(`${fixture.name}, ${fixture.target}, ${bundle ? 'bundle' : 'single'}, ${minify ? 'minify' : 'plain'}`, async () => {
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
            `--target=${fixture.target}`,
            ...(minify ? ['--minify'] : []),
            '-o', output,
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
