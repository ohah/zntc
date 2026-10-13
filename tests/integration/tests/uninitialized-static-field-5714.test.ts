import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5714: lowering class fields (es2021 and below) dropped a static field
// without an initializer. Under define semantics (the default) it must exist
// as `undefined` (`'y' in C === true`), in source order with the other static
// elements. Node runs the source natively for the expected output.
const source = `class A { static y; static { console.log('y' in A, Object.keys(A).join()); } static z = 1; }
class B { static y; x = 1; static [Symbol.iterator]; }
class C { static #p = 1; static q; static { console.log('q' in C); } static get p() { return C.#p; } }
console.log('y' in B, Symbol.iterator in B, C.p, Object.keys(B).join());
`;

describe('uninitialized static fields under define semantics (#5714)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const target of ['es2021', 'es2015', 'es5']) {
    for (const extra of [[], ['--minify'], ['--bundle']]) {
      test(`${target} ${extra.join(' ')}`, async () => {
        const created = await createFixture({ 'entry.js': source });
        cleanup = created.cleanup;
        const expected = spawnSync('node', [join(created.dir, 'entry.js')], { encoding: 'utf8' });
        expect(expected.status, expected.stderr).toBe(0);
        const out = join(created.dir, 'out.cjs');
        const result = await runZntc([
          join(created.dir, 'entry.js'),
          `--target=${target}`,
          ...extra,
          '-o',
          out,
        ]);
        expect(result.exitCode, result.stderr).toBe(0);
        const run = spawnSync('node', [out], { encoding: 'utf8' });
        expect(run.status, run.stderr).toBe(0);
        expect(run.stdout).toBe(expected.stdout);
      });
    }
  }

  test('assign semantics still elides it, like tsc', async () => {
    const created = await createFixture({
      'entry.ts': 'class A { static y: number; }\nconsole.log("y" in A);\n',
    });
    cleanup = created.cleanup;
    const out = join(created.dir, 'out.cjs');
    const result = await runZntc([
      join(created.dir, 'entry.ts'),
      '--target=es2021',
      '--use-define-for-class-fields=false',
      '-o',
      out,
    ]);
    expect(result.exitCode, result.stderr).toBe(0);
    expect(spawnSync('node', [out], { encoding: 'utf8' }).stdout).toBe('false\n');
  });
});
