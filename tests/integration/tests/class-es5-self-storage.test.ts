import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntcInDir } from './helpers';

const source = `
  class C { static self() { return C; } }
  const original = C;
  C = class Replacement {};
  const Expr = class Named extends Object { static self() { return Named; } };
  const named = Expr;
  function make() {
    class C { static self() { return C; } }
    return C;
  }
  const first = make();
  const second = make();
  console.log(JSON.stringify([
    original.self() === original, named.self() === named,
    first !== second, first.self() === first, second.self() === second,
  ]));
`;

describe('ES5 class self storage (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const bundle of [false, true]) {
    for (const minify of [false, true]) {
      test(`${bundle ? 'bundle' : 'single'}, ${minify ? 'minify' : 'plain'}`, async () => {
        const fixture = await createFixture({
          'input.mjs': source,
          'package.json': '{"type":"module"}',
        });
        cleanup = fixture.cleanup;
        const native = spawnSync('node', [join(fixture.dir, 'input.mjs')], { encoding: 'utf8' });
        expect(native.status, native.stderr).toBe(0);
        const output = join(fixture.dir, 'out.mjs');
        const result = await runZntcInDir(fixture.dir, [
          ...(bundle ? ['--bundle', '--platform=node', '--format=esm'] : []),
          'input.mjs', '--target=es5',
          ...(minify ? ['--minify-identifiers', '--minify-syntax'] : []),
          '-o', output,
        ]);
        expect(result.exitCode, result.stderr).toBe(0);
        const runtime = spawnSync('node', [output], { encoding: 'utf8' });
        expect(runtime.status, runtime.stderr).toBe(0);
        expect(runtime.stdout).toBe(native.stdout);
      });
    }
  }
});
