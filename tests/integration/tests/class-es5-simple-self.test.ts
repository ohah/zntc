import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntcInDir } from './helpers';

const cases = [
  'const X = class C { constructor(C) { this.value = C; } }; console.log(new X(3).value, X.name);',
  'const X = class C { constructor(source) { this.value = source() ?? 3; } }; console.log(new X(() => null).value, X.name);',
  'const X = class C { constructor() { var C = 3; this.value = C; } }; console.log(new X().value, X.name);',
  'const X = class C { constructor() { this.self = C; } }; console.log(new X().self === X, X.name);',
  'const X = class C {}; console.log(new X() instanceof X, X.name);',
  'let X = class C { constructor() { this.self = C; } }; const Original = X; X = function Other() {}; console.log(new Original().self === Original, Original.name);',
  'const X = class _classSelf { constructor(_classSelf) { this.value = _classSelf; } }; console.log(new X(4).value, X.name);',
  'function make() { return class C { constructor(C) { this.value = C; } }; } const A = make(), B = make(); console.log(new A(1).value, new B(2).value, A !== B, A.name);',
  'const X = class C { constructor(value = C) { this.value = value; } }; console.log(new X().value === X, X.name);',
  'const X = class C { handler = () => this.value; value = 7; }; console.log(new X().handler(), X.name);',
  'const X = class C { handler = () => this.value; constructor(value) { this.value = value; } }; console.log(new X(8).handler(), X.name);',
];

describe('ES5 simple named class self (#4819)', () => {
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
