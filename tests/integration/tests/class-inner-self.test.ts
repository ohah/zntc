import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntcInDir } from './helpers';

const source = `
  export class C {
    static capture() { return C; }
    static mutate() { C = 42; }
  }
  const original = C;
  let mutation = 'none';
  try { C.mutate(); } catch (error) { mutation = error.name; }
  C = class Replacement {};
  let declarationHeritage = 'none';
  try { class Shadow extends Shadow {} } catch (error) { declarationHeritage = error.name; }
  let expressionHeritage = 'none';
  try { const Value = class Named extends Named {}; void Value; }
  catch (error) { expressionHeritage = error.name; }
  console.log(JSON.stringify([original.capture() === original, mutation, C !== original,
    declarationHeritage, expressionHeritage]));
`;

describe('class inner self binding (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const target of ['esnext', 'es2015']) {
    for (const bundle of [false, true]) {
      for (const minify of [false, true]) {
        test(`${target}, ${bundle ? 'bundle' : 'single'}, ${minify ? 'minify' : 'plain'}`, async () => {
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
            'input.mjs',
            `--target=${target}`,
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
  }

  for (const minify of [false, true]) {
    test(`bundle deconflicts two exported class self bindings, ${minify ? 'minify' : 'plain'}`, async () => {
      const fixture = await createFixture({
        'a.mjs': 'export class Node { static self() { return Node; } static { this.saved = Node; } }',
        'b.mjs': 'export class Node { static self() { return Node; } }',
        'entry.mjs': `import { Node as A } from './a.mjs';
          import { Node as B } from './b.mjs';
          globalThis.Node = class HostNode {};
          console.log(JSON.stringify([A.self() === A, A.saved === A, B.self() === B,
            globalThis.Node !== A && globalThis.Node !== B]));`,
        'package.json': '{"type":"module"}',
      });
      cleanup = fixture.cleanup;
      const native = spawnSync('node', [join(fixture.dir, 'entry.mjs')], { encoding: 'utf8' });
      expect(native.status, native.stderr).toBe(0);
      const output = join(fixture.dir, 'out.mjs');
      const result = await runZntcInDir(fixture.dir, [
        '--bundle', '--platform=node', '--format=esm', 'entry.mjs', '--target=esnext',
        ...(minify ? ['--minify-identifiers', '--minify-syntax'] : []), '-o', output,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);
      const runtime = spawnSync('node', [output], { encoding: 'utf8' });
      expect(runtime.status, runtime.stderr).toBe(0);
      expect(runtime.stdout).toBe(native.stdout);
    });
  }
});
