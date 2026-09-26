import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import ts from 'typescript';
import { createFixture, runZntcInDir } from './helpers';

describe('ambient namespace and enum markers (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const bundled of [false, true]) {
    for (const minify of [false, true]) {
      test(`${bundled ? 'bundle' : 'single-file'} preserves ambient references (${minify ? 'minify' : 'plain'})`, async () => {
        const source = `
globalThis.Hidden = { value: 3 };
globalThis.Numbers = { A: 4 };
namespace Outer {
  export declare namespace Hidden { export const value: number; }
  export declare enum Numbers { A = 1 }
  console.log(Hidden.value + Numbers.A);
}
`;
        const reference = ts.transpileModule(source, {
          compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.None },
        }).outputText;
        const fixture = await createFixture({ 'input.ts': source, 'reference.cjs': reference });
        cleanup = fixture.cleanup;
        // TypeScript keeps ambient namespace/enum references unqualified.
        // The test checks their runtime lookup using the matching outer values.
        const native = spawnSync('node', [join(fixture.dir, 'reference.cjs')], {
          encoding: 'utf8',
        });
        expect(native.status).toBe(0);
        expect(native.stdout.trim()).toBe('7');
        const out = join(fixture.dir, 'out.cjs');
        const result = await runZntcInDir(fixture.dir, [
          ...(bundled ? ['--bundle'] : []),
          'input.ts',
          '--target=es5',
          ...(minify ? ['--minify-identifiers', '--minify-syntax'] : []),
          ...(bundled ? ['--platform=node', '--format=cjs'] : []),
          '-o',
          out,
        ]);
        expect(result.exitCode).toBe(0);
        const runtime = spawnSync('node', [out], { encoding: 'utf8' });
        expect(runtime.status).toBe(0);
        expect(runtime.stdout).toBe(native.stdout);
      });
    }
  }
});
