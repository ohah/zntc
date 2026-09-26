import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import ts from 'typescript';
import { createFixture, runZntcInDir } from './helpers';

const source = `
const events: string[] = [];
(Reflect as any).metadata = function (key: string, value: any) {
  return function (_target: any, property?: string) {
    const names = Array.isArray(value) ? value.map(item => item.name).join(',') : value.name;
    events.push((property || 'class') + ':' + key + ':' + names);
  };
};
function decorated(_target: any, property?: string) {
  events.push('decorate:' + (property || 'class'));
}
@decorated
class Service {
  constructor(value: number) {}
  @decorated method(value: string): number { return value.length; }
}
console.log(JSON.stringify([new Service(1).method('abc'), events]));
`;

describe('legacy runtime helper symbols (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const metadata of [false, true]) {
    for (const mode of ['single', 'bundle', 'split'] as const) {
      for (const minify of [false, true]) {
        test(`${metadata ? 'metadata' : 'decorator'}: ${mode}, ${minify ? 'minify' : 'plain'}`, async () => {
          const reference = ts.transpileModule(source, {
            compilerOptions: {
              experimentalDecorators: true,
              emitDecoratorMetadata: metadata,
              target: ts.ScriptTarget.ES2020,
              module: ts.ModuleKind.ESNext,
            },
          }).outputText;
          const fixture = await createFixture({
            'input.ts': source,
            'entry.ts': "import('./input');",
            'package.json': '{"type":"module"}',
            'reference.mjs': reference,
            'tsconfig.json': JSON.stringify({
              compilerOptions: {
                experimentalDecorators: true,
                emitDecoratorMetadata: metadata,
              },
            }),
          });
          cleanup = fixture.cleanup;
          const native = spawnSync('node', [join(fixture.dir, 'reference.mjs')], {
            encoding: 'utf8',
          });
          expect(native.status).toBe(0);
          expect(native.stdout.trim().length).toBeGreaterThan(0);
          const out = join(fixture.dir, mode === 'split' ? 'dist/entry.js' : 'out.cjs');
          const result = await runZntcInDir(fixture.dir, [
            ...(mode === 'single' ? [] : ['--bundle']),
            mode === 'split' ? 'entry.ts' : 'input.ts',
            '--target=es2020',
            ...(minify ? ['--minify-identifiers', '--minify-syntax'] : []),
            ...(mode === 'single' ? [] : ['--platform=node']),
            ...(mode === 'split'
              ? ['--format=esm', '--splitting', '--outdir=dist']
              : [...(mode === 'bundle' ? ['--format=cjs'] : []), '-o', out]),
          ]);
          expect(result.exitCode).toBe(0);
          const runtime = spawnSync('node', [out], { encoding: 'utf8' });
          expect(runtime.status).toBe(0);
          expect(runtime.stdout).toBe(native.stdout);
        });
      }
    }
  }
});
