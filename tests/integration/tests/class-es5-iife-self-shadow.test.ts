import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntcInDir } from './helpers';

const cases = [
  'const X = class Inner { constructor(Inner) { this.value = Inner; } static self() { return Inner; } }; console.log(new X(7).value, X.self() === X, X.name);',
  'const X = class Inner { constructor() { var Inner = 8; this.value = Inner; } static self() { return Inner; } }; console.log(new X().value, X.self() === X, X.name);',
  'const X = class Inner { constructor(Inner = 9) { this.value = Inner; } static self() { return Inner; } }; console.log(new X().value, X.self() === X, X.name);',
  'const X = class Inner extends Object { constructor(Inner) { super(); this.value = Inner; } static self() { return Inner; } }; console.log(new X(10).value, X.self() === X, X.name);',
  'let X = class Inner { constructor(Inner) { this.value = Inner; } static self() { return Inner; } }; const Original = X; X = class Replacement {}; console.log(new Original(11).value, Original.self() === Original, Original.name);',
  'function make() { return class Inner { constructor(Inner) { this.value = Inner; } static self() { return Inner; } }; } const A = make(), B = make(); console.log(new A(1).value, new B(2).value, A !== B, A.self() === A, B.self() === B);',
  'const _classSelf = 99; const X = class Inner { constructor(Inner) { this.value = Inner; } static self() { return Inner; } }; console.log(new X(12).value, X.self() === X, _classSelf);',
  'class Inner { constructor(Inner) { this.value = Inner; } static self() { return Inner; } } console.log(new Inner(13).value, Inner.self() === Inner, Inner.name);',
  'class Inner extends Object { constructor(Inner) { super(); this.value = Inner; } static self() { return Inner; } } console.log(new Inner(14).value, Inner.self() === Inner, Inner.name);',
  'class Inner { constructor(Inner) { this.value = Inner; } static self() { return Inner; } } const Original = Inner; Inner = class Replacement {}; console.log(new Original(15).value, Original.self() === Original, Original.name);',
];

describe('ES5 class IIFE constructor self check (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const bundle of [false, true]) {
    for (const minify of [false, true]) {
      test(`${bundle ? 'bundle' : 'single'}, ${minify ? 'minify' : 'plain'}`, async () => {
        const fixture = await createFixture({
          'input.mjs': cases.map((source) => `{ ${source} }`).join('\n'),
          'package.json': '{"type":"module"}',
        });
        cleanup = fixture.cleanup;
        const native = spawnSync('node', [join(fixture.dir, 'input.mjs')], { encoding: 'utf8' });
        expect(native.status, native.stderr).toBe(0);
        const output = join(fixture.dir, 'out.mjs');
        const result = await runZntcInDir(fixture.dir, [
          ...(bundle ? ['--bundle', '--platform=node', '--format=esm'] : []),
          'input.mjs',
          '--target=es5',
          ...(minify ? ['--minify-identifiers', '--minify-syntax'] : []),
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
