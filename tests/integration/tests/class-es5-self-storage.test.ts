import { afterEach, describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
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

  for (const minify of [false, true]) {
    test(`repeated class-self write targets keep exact names, ${minify ? 'minified' : 'plain'}`, async () => {
      const input = `
        class First { static write() { First = 3; } }
        class Second { static write() { Second = 4; } }
        const errors = [];
        for (const value of [First, Second]) {
          try { value.write(); errors.push('none'); }
          catch (error) { errors.push(error.name); }
        }
        console.log(JSON.stringify(errors));
      `;
      const fixture = await createFixture({
        'input.mjs': input,
        'package.json': '{"type":"module"}',
      });
      cleanup = fixture.cleanup;
      const native = spawnSync('node', [join(fixture.dir, 'input.mjs')], { encoding: 'utf8' });
      expect(native.status, native.stderr).toBe(0);
      const output = join(fixture.dir, 'out.mjs');
      const result = await runZntcInDir(fixture.dir, [
        'input.mjs',
        '--target=es5',
        ...(minify ? ['--minify-identifiers', '--minify-syntax'] : []),
        '-o',
        output,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);
      const code = readFileSync(output, 'utf8');
      if (minify) {
        expect(code).not.toContain('_classSelfWrite');
        expect(code).not.toContain('_classSelfReadonly');
        expect(code).not.toContain('_ignoredClassSelfWrite');
      } else {
        for (const baseName of [
          '_classSelfWrite',
          '_classSelfReadonly',
          '_ignoredClassSelfWrite',
        ]) {
          expect(code).toContain(baseName);
          expect(code).toContain(`${baseName}2`);
        }
      }
      const runtime = spawnSync('node', [output], { encoding: 'utf8' });
      expect(runtime.status, runtime.stderr).toBe(0);
      expect(runtime.stdout).toBe(native.stdout);
    });
  }

  for (const minify of [false, true]) {
    test(`constructor class-name aliases resolve by SymbolId, ${minify ? 'minified' : 'plain'}`, async () => {
      const input = `
        class First { constructor(First) { this.arg = First; } static self() { return First; } }
        class Second { constructor(Second) { this.arg = Second; } static self() { return Second; } }
        const values = [new First(1), new Second(2)];
        console.log(JSON.stringify(values.map((value) => [value.arg, value.constructor.self() === value.constructor])));
      `;
      const fixture = await createFixture({
        'input.mjs': input,
        'package.json': '{"type":"module"}',
      });
      cleanup = fixture.cleanup;
      const native = spawnSync('node', [join(fixture.dir, 'input.mjs')], { encoding: 'utf8' });
      expect(native.status, native.stderr).toBe(0);
      const output = join(fixture.dir, 'out.mjs');
      const result = await runZntcInDir(fixture.dir, [
        'input.mjs',
        '--target=es5',
        ...(minify ? ['--minify-identifiers', '--minify-syntax'] : []),
        '-o',
        output,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);
      const code = readFileSync(output, 'utf8');
      if (minify) {
        expect(code).not.toContain('_classSelf');
      } else {
        expect(code).toContain('_classSelf');
        expect(code).toContain('_classSelf2');
      }
      const runtime = spawnSync('node', [output], { encoding: 'utf8' });
      expect(runtime.status, runtime.stderr).toBe(0);
      expect(runtime.stdout).toBe(native.stdout);
    });
  }

  test('source names cannot be captured by class-self generated bindings', async () => {
    const input = `
      const _classSelfWrite = 'source';
      const _classSelfReadonly = 'readonly source';
      const _ignoredClassSelfWrite = 'ignored source';
      const _classSelf = 'alias source';
      class CollisionTarget {
        constructor(CollisionTarget) { this.value = CollisionTarget; }
        static write() { CollisionTarget = 3; }
        static readSource() { return [_classSelfWrite, _classSelfReadonly, _ignoredClassSelfWrite, _classSelf]; }
      }
      let writeError = 'none';
      try { CollisionTarget.write(); } catch (error) { writeError = error.name; }
      console.log(JSON.stringify([CollisionTarget.readSource(), writeError]));
    `;
    const fixture = await createFixture({
      'input.mjs': input,
      'package.json': '{"type":"module"}',
    });
    cleanup = fixture.cleanup;
    const native = spawnSync('node', [join(fixture.dir, 'input.mjs')], { encoding: 'utf8' });
    expect(native.status, native.stderr).toBe(0);
    const output = join(fixture.dir, 'out.mjs');
    const result = await runZntcInDir(fixture.dir, ['input.mjs', '--target=es5', '-o', output]);
    expect(result.exitCode, result.stderr).toBe(0);
    const code = readFileSync(output, 'utf8');
    expect(code).toContain('_classSelfWrite2');
    expect(code).toContain('_classSelfReadonly2');
    expect(code).toContain('_ignoredClassSelfWrite2');
    expect(code).toContain('_classSelf2');
    const runtime = spawnSync('node', [output], { encoding: 'utf8' });
    expect(runtime.status, runtime.stderr).toBe(0);
    expect(runtime.stdout).toBe(native.stdout);
  });

  test('direct eval keeps the class-self write name away from eval-visible globals', async () => {
    const input = `
      globalThis._classSelfWrite = 'global';
      globalThis._classSelfReadonly = 'readonly';
      globalThis._ignoredClassSelfWrite = 'ignored';
      globalThis._classSelf = 'alias';
      class EvalTarget {
        constructor(EvalTarget) { this.value = EvalTarget; }
        static write() { EvalTarget = 3; }
        static readGlobal() {
          return eval('_classSelfWrite + ":" + _classSelfReadonly + ":" + _ignoredClassSelfWrite + ":" + _classSelf');
        }
      }
      console.log(JSON.stringify(EvalTarget.readGlobal()));
    `;
    const fixture = await createFixture({
      'input.mjs': input,
      'package.json': '{"type":"module"}',
    });
    cleanup = fixture.cleanup;
    const native = spawnSync('node', [join(fixture.dir, 'input.mjs')], { encoding: 'utf8' });
    expect(native.status, native.stderr).toBe(0);
    const output = join(fixture.dir, 'out.mjs');
    const result = await runZntcInDir(fixture.dir, ['input.mjs', '--target=es5', '-o', output]);
    expect(result.exitCode, result.stderr).toBe(0);
    const code = readFileSync(output, 'utf8');
    expect(code).toContain('_classSelfWrite2');
    expect(code).toContain('_classSelfReadonly2');
    expect(code).toContain('_ignoredClassSelfWrite2');
    expect(code).toContain('_classSelf2');
    const runtime = spawnSync('node', [output], { encoding: 'utf8' });
    expect(runtime.status, runtime.stderr).toBe(0);
    expect(runtime.stdout).toBe(native.stdout);
  });

  for (const minify of [false, true]) {
    test(`anonymous default class keeps exact export and eval names, ${minify ? 'minified' : 'plain'}`, async () => {
      const input = `
        globalThis._Class3 = 'global';
        const _Class = 'source';
        const _Class2 = 'source2';
        class Base { static read() { return 'base'; } }
        export default class extends Base {
          static read() { return [_Class, _Class2, eval('_Class3'), super.read()]; }
        }
      `;
      const fixture = await createFixture({
        'input.mjs': input,
        'package.json': '{"type":"module"}',
      });
      cleanup = fixture.cleanup;
      const inputPath = join(fixture.dir, 'input.mjs');
      const native = spawnSync(
        'node',
        [
          '--input-type=module',
          '-e',
          'const { default: C } = await import(process.argv[1]); console.log(JSON.stringify(C.read()));',
          inputPath,
        ],
        { cwd: fixture.dir, encoding: 'utf8' },
      );
      expect(native.status, native.stderr).toBe(0);
      const output = join(fixture.dir, 'out.mjs');
      const result = await runZntcInDir(fixture.dir, [
        'input.mjs',
        '--target=es5',
        ...(minify ? ['--minify-identifiers', '--minify-syntax'] : []),
        '-o',
        output,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);
      const code = readFileSync(output, 'utf8');
      if (!minify) expect(code).toContain('_Class4');
      const runtime = spawnSync(
        'node',
        [
          '--input-type=module',
          '-e',
          'const { default: C } = await import(process.argv[1]); console.log(JSON.stringify(C.read()));',
          output,
        ],
        { cwd: fixture.dir, encoding: 'utf8' },
      );
      expect(runtime.status, runtime.stderr).toBe(0);
      expect(runtime.stdout).toBe(native.stdout);
    });
  }

  for (const bundle of [false, true]) {
    test(`anonymous default class export follows its finalized SymbolId name, ${bundle ? 'bundle' : 'single'}`, async () => {
      const fixture = await createFixture({
        'input.mjs': 'export default class { static read() { return 42; } }',
        'package.json': '{"type":"module"}',
      });
      cleanup = fixture.cleanup;
      const inputPath = join(fixture.dir, 'input.mjs');
      const script = 'const { default: C } = await import(process.argv[1]); console.log(C.read());';
      const native = spawnSync('node', ['--input-type=module', '-e', script, inputPath], {
        cwd: fixture.dir,
        encoding: 'utf8',
      });
      expect(native.status, native.stderr).toBe(0);
      const output = join(fixture.dir, 'out.mjs');
      const result = await runZntcInDir(fixture.dir, [
        ...(bundle ? ['--bundle', '--platform=node', '--format=esm'] : []),
        'input.mjs',
        '--target=es5',
        '-o',
        output,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);
      const runtime = spawnSync('node', ['--input-type=module', '-e', script, output], {
        cwd: fixture.dir,
        encoding: 'utf8',
      });
      expect(runtime.status, runtime.stderr).toBe(0);
      expect(runtime.stdout).toBe(native.stdout);
    });
  }
});
