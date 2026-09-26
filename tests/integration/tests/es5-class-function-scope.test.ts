import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import ts from 'typescript';
import { createFixture, runZntcInDir } from './helpers';

const cases = {
  'computed method and paired accessors': `
    const key = 'read';
    class Box {
      stamp = 0;
      constructor(source) { this.value = source() ?? 4; }
      [key](source) { return source() ?? this.value; }
      get current() { return this.value ?? 0; }
      set current(source) { this.value = source() ?? 1; }
    }
    const box = new Box(() => null);
    const first = box.read(() => null);
    box.current = () => 7;
    console.log(JSON.stringify([first, box.current, box.read(() => 2)]));
  `,
  'direct class expression constructor': `
    const Direct = class {
      constructor(source) { this.value = source() ?? 3; }
    };
    console.log(JSON.stringify([new Direct(() => null).value, new Direct(() => 8).value]));
  `,
  'nested closures in computed method': `
    const key = 'make';
    class Box {
      [key](source) {
        const local = source() ?? 5;
        return () => local + (source() ?? 1);
      }
    }
    const box = new Box();
    const read = box.make(() => null);
    console.log(read());
  `,
  // Stage 3 computed-key runtime evaluation has a separate existing defect.
  // The computed owner copies are checked by the semantic tests.
  'decorated async method with field': `
    const calls = [];
    function trace(method, context) {
      calls.push(context.name);
      return function(...args) { return method.apply(this, args); };
    }
    class Box {
      value = 6;
      @trace
      async read(offset) { return this.value + await Promise.resolve(offset); }
    }
    new Box().read(2).then(value => console.log(JSON.stringify([calls, value])));
  `,
} as const;

describe('ES5 class function scope (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const [name, source] of Object.entries(cases)) {
    for (const bundle of [false, true]) {
      for (const minify of [false, true]) {
        test(`${name}, ${bundle ? 'bundle' : 'single'}, ${minify ? 'minify' : 'plain'}`, async () => {
          const reference = ts.transpileModule(source, {
            compilerOptions: {
              target: ts.ScriptTarget.ES5,
              module: ts.ModuleKind.ESNext,
            },
          }).outputText;
          const fixture = await createFixture({
            'input.ts': source,
            'package.json': '{"type":"module"}',
            'reference.mjs': reference,
          });
          cleanup = fixture.cleanup;
          const native = spawnSync('node', [join(fixture.dir, 'reference.mjs')], {
            encoding: 'utf8',
          });
          expect(native.status, native.stderr).toBe(0);
          const output = join(fixture.dir, 'out.cjs');
          const result = await runZntcInDir(fixture.dir, [
            ...(bundle ? ['--bundle', '--platform=node', '--format=cjs'] : []),
            'input.ts',
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
  }
});
