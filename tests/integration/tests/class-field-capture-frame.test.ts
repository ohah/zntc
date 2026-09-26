import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntcInDir } from './helpers';

const cases = {
  'explicit constructor shares field and body capture': `
    class Box {
      field = () => this.value;
      constructor(value) { this.value = value; this.body = () => this.value; }
    }
    const box = new Box(7);
    console.log(JSON.stringify([box.field(), box.body()]));
  `,
  'synthesized constructor and class expression': `
    class Box { field = () => this.value; value = 8; }
    const Other = class { field = () => this.value; value = 9; };
    console.log(JSON.stringify([new Box().field(), new Other().field()]));
  `,
  'derived explicit and synthesized constructors': `
    class Base { constructor() { this.value = 1; } }
    class Explicit extends Base {
      field = () => this.value;
      constructor() { super(); this.value = 10; this.body = () => this.value; }
    }
    class Synthesized extends Base { field = () => this.value; value = 11; }
    const explicit = new Explicit();
    console.log(JSON.stringify([explicit.field(), explicit.body(), new Synthesized().field()]));
  `,
  'private field and nested capture with shadowed alias text': `
    const _this = 100;
    class Box {
      #value = 12;
      field = () => (() => this.#value + _this)();
    }
    console.log(new Box().field());
  `,
} as const;

describe('ES5 class field lexical capture frame (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const [name, source] of Object.entries(cases)) {
    for (const target of ['es5', 'es2015']) {
      for (const bundle of [false, true]) {
        for (const minify of [false, true]) {
          test(`${name}, ${target}, ${bundle ? 'bundle' : 'single'}, ${minify ? 'minify' : 'plain'}`, async () => {
            const fixture = await createFixture({
              'input.mjs': source,
              'package.json': '{"type":"module"}',
            });
            cleanup = fixture.cleanup;
            const native = spawnSync('node', [join(fixture.dir, 'input.mjs')], { encoding: 'utf8' });
            expect(native.status, native.stderr).toBe(0);
            const output = join(fixture.dir, bundle ? 'out.cjs' : 'out.mjs');
            const transformed = await runZntcInDir(fixture.dir, [
              ...(bundle ? ['--bundle', '--platform=node', '--format=cjs'] : []),
              'input.mjs',
              `--target=${target}`,
              ...(minify ? ['--minify'] : []),
              '-o',
              output,
            ]);
            expect(transformed.exitCode, transformed.stderr).toBe(0);
            const actual = spawnSync('node', [output], { encoding: 'utf8' });
            expect(actual.status, actual.stderr).toBe(0);
            expect(actual.stdout).toBe(native.stdout);
          });
        }
      }
    }
  }
});
