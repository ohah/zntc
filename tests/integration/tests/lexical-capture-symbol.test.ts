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
    name: 'sloppy arguments parameter keeps its source binding',
    target: 'es5',
    file: 'input.cjs',
    source: `function outer(arguments) {
      const first = () => arguments;
      const local = (arguments) => arguments;
      function inner(arguments) { return () => arguments; }
      return [first(), local(11), inner(7)()];
    }
    console.log(outer(3).join(','));`,
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
  {
    name: 'optional chain copies of capture references',
    target: 'es5',
    source: `function run(value) {
      return (() => this?.base ?? arguments[0])();
    }
    console.log(run.call({ base: 2 }, 3));`,
  },
  {
    name: 'for-await capture in kept async generator',
    target: 'es2015',
    source: `async function* collect(items) {
      for await (const item of items) {
        yield (() => this.base + arguments.length + item)();
      }
    }
    async function main() {
      const values = [];
      for await (const value of collect.call({ base: 2 }, [1])) values.push(value);
      console.log(values.join(','));
    }
    main();`,
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
      // Existing CJS bundling inserts strict mode; `arguments` cannot be a
      // parameter there, so this source is meaningful only as standalone CJS.
      if ('file' in fixture && bundle) continue;
      for (const minify of [false, true]) {
        test(`${fixture.name}, ${fixture.target}, ${bundle ? 'bundle' : 'single'}, ${minify ? 'minify' : 'plain'}`, async () => {
          const file = 'file' in fixture ? fixture.file : 'input.mjs';
          const dir = await createFixture({
            [file]: fixture.source,
            'package.json': '{"type":"module"}',
          });
          cleanup = dir.cleanup;
          const input = join(dir.dir, file);
          const native = spawnSync('node', [input], { encoding: 'utf8' });
          expect(native.status, native.stderr).toBe(0);
          const output = join(dir.dir, bundle || file.endsWith('.cjs') ? 'out.cjs' : 'out.mjs');
          const result = await runZntcInDir(dir.dir, [
            ...(bundle ? ['--bundle', '--platform=node', '--format=cjs'] : []),
            file,
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
