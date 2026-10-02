import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import ts from 'typescript';
import { createFixture, runZntcInDir, ZNTC_BIN } from './helpers';

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
  .replace(
    '@decorated method(value: string): any { return value.length; }',
    '@decorated method(): any { return 3; }',
  )
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

  test('metadata references retain nested classes and shadowed built-ins in the transform graph', async () => {
    const metadataSource = `
import type { Phantom } from './types';
import { type Phantom as a } from './types';
const events: string[] = [];
function decorate(): any { return () => {}; }
function build(Number: any, Object: any) {
  class LocalType { static marker = 'local-type'; }
  const expectedNumber = Number;
  const expectedObject = Object;
  const expectedLocalType = LocalType;
  (Reflect as any).metadata = (key: string, value: any) => (_target: any, property?: string) => {
    if (key !== 'design:paramtypes') return;
    const names = value.map((item: any) =>
      item === expectedNumber ? 'shadowed-number' :
      item === expectedObject ? 'shadowed-object' :
      item === expectedLocalType ? 'local-class' :
      item === globalThis.Object ? 'global-object' : 'other');
    events.push((property ?? 'class') + ':' + names.join(','));
  };
  @decorate()
  class Service {
    constructor(number: number, local: LocalType, phantom: Phantom, inlinePhantom: a) {}
    @decorate() method(local: LocalType) { return local; }
  }
  return Service;
}
class ShadowNumber {}
class ShadowObject {}
const Service = build(ShadowNumber, ShadowObject);
new Service(ShadowNumber, ShadowObject, Service).method(Service);
console.log(events.join('|'));
`;
    const fixture = await createFixture({
      'input.ts': metadataSource,
      'tsconfig.json': JSON.stringify({
        compilerOptions: { experimentalDecorators: true, emitDecoratorMetadata: true },
      }),
    });
    cleanup = fixture.cleanup;

    const reference = ts.transpileModule(metadataSource, {
      compilerOptions: {
        experimentalDecorators: true,
        emitDecoratorMetadata: true,
        target: ts.ScriptTarget.ES2020,
        module: ts.ModuleKind.CommonJS,
      },
    }).outputText;
    writeFileSync(join(fixture.dir, 'reference.js'), reference);
    const native = spawnSync('node', [join(fixture.dir, 'reference.js')], { encoding: 'utf8' });
    expect(native.status, native.stderr).toBe(0);

    const output = join(fixture.dir, 'out.js');
    const proc = spawnSync(
      ZNTC_BIN,
      ['input.ts', '--minify-identifiers', '--minify-syntax', '-o', output],
      {
        cwd: fixture.dir,
        env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
        encoding: 'utf8',
      },
    );
    expect(proc.status, proc.stderr).toBe(0);
    const runtime = spawnSync('node', [output], { encoding: 'utf8' });
    expect(runtime.status, runtime.stderr).toBe(0);
    expect(runtime.stdout).toBe(native.stdout);

    const exact = proc.stderr
      .split('\n')
      .find((line) => line.includes('zntc: symbol-identity input.ts:'));
    expect(exact).toContain('shadowed_external_reference=0');
    expect(exact).toContain('missing_binding=0');
    expect(exact).toContain('identity_mismatch=0');
    expect(exact).toContain('clean=1');
    expect(proc.stderr).toMatch(
      /symbol-identity-post-minify .* missing_binding_id=0 missing_reference_id=0 dangling_reference_id=0 wrong_reference_target=0 clean=1/,
    );
  });
});
