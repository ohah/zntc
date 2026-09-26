import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import ts from 'typescript';
import { createFixture, runZntcInDir } from './helpers';

// Return-type metadata currently emits Object for every method. Explicit any
// keeps this helper-linkage fixture inside that supported serialization case.
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
  @decorated method(value: string): any { return value.length; }
}
console.log(JSON.stringify([new Service(1).method('abc'), events]));
`;

// ES5 class lowering currently loses typed method/constructor parameter
// metadata. This variant still exercises __metadata for a decorated method,
// without treating that separate serialization gap as helper linkage.
const es5MetadataSource = source
  .replace('  constructor(value: number) {}\n', '')
  .replace('@decorated method(value: string): any { return value.length; }', '@decorated method(): any { return 3; }')
  .replace("new Service(1).method('abc')", 'new Service().method()');

describe('legacy runtime helper symbols (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const target of ['es5', 'es2020'] as const) {
    for (const metadata of [false, true]) {
      for (const mode of ['single', 'bundle', 'split'] as const) {
        for (const minify of [false, true]) {
          test(`${target}, ${metadata ? 'metadata' : 'decorator'}: ${mode}, ${minify ? 'minify' : 'plain'}`, async () => {
            const fixtureSource = target === 'es5' && metadata ? es5MetadataSource : source;
            const reference = ts.transpileModule(fixtureSource, {
              compilerOptions: {
                experimentalDecorators: true,
                emitDecoratorMetadata: metadata,
                target: target === 'es5' ? ts.ScriptTarget.ES5 : ts.ScriptTarget.ES2020,
                module: ts.ModuleKind.ESNext,
              },
            }).outputText;
            const fixture = await createFixture({
              'input.ts': fixtureSource,
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
              `--target=${target}`,
              ...(minify ? ['--minify-identifiers', '--minify-syntax'] : []),
              ...(mode === 'single' ? [] : ['--platform=node']),
              ...(mode === 'split'
                ? ['--format=esm', '--splitting', '--outdir', 'dist']
                : [...(mode === 'bundle' ? ['--format=cjs'] : []), '-o', out]),
            ]);
            expect(result.exitCode, result.stderr).toBe(0);
            const runtime = spawnSync('node', [out], { encoding: 'utf8' });
            expect(runtime.status).toBe(0);
            expect(runtime.stdout).toBe(native.stdout);
          });
        }
      }
    }
  }
});
