import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import ts from 'typescript';
import { createFixture, runZntcInDir } from './helpers';

const cases = {
  'shadowed parameters and locals': `
namespace N {
  export const value = 1;
  export function param(value: number) { return value + 2; }
  export function local() { const value = 4; return value + 3; }
  export function nested() { function inner(value: number) { return value + 5; } return inner(6); }
}
console.log(JSON.stringify([N.value, N.param(3), N.local(), N.nested()]));
`,
  'generated IIFE parameter collision': `
namespace N {
  export const N = 1;
  export function read() { const _N = { N: 99 }; return N; }
}
console.log(JSON.stringify([N.N, N.read()]));
`,
  'nested namespace reads, writes and shorthand': `
namespace Outer {
  export let count = 1;
  export function read() { return count; }
  export function bump() { return ++count; }
  export function shorthand() { return { count }; }
  export function local() { let count = 7; return { count }.count; }
  export namespace Inner {
    export let child = count + 2;
    export function parent() { return count; }
    export function shadow(count: number) { return count + child; }
  }
}
console.log(JSON.stringify([Outer.read(), Outer.bump(), Outer.shorthand(), Outer.local(), Outer.Inner.child, Outer.Inner.parent(), Outer.Inner.shadow(11)]));
`,
  'exported enum stays reachable as namespace property': `
namespace N {
  export enum E { A = 1 }
  export function read() { return E.A; }
}
console.log(JSON.stringify([N.E.A, N.read()]));
`,
  'dotted namespace and generated-name collisions': `
namespace A.B {
  export let A = 1;
  export let B = 2;
  export function f() { const _B = { A: 99 }; return A + B + _B.A; }
}
console.log(JSON.stringify([A.B.A, A.B.B, A.B.f()]));
`,
  'merged namespace declarations share exported storage': `
namespace N {
  export let value = 1;
  export function first() { return value; }
}
namespace N {
  export let next = value + 2;
  export function read() { const value = 9; return [value, next, first()]; }
  export function bump() { return ++value; }
}
console.log(JSON.stringify([N.value, N.next, N.read(), N.bump(), N.first()]));
`,
  'merged exported enums retain earlier members': `
namespace N { export enum E { A = 1 } }
namespace N { export enum E { B = 2 } }
console.log(JSON.stringify([N.E.A, N.E.B]));
`,
  'nested merged namespace declarations keep both lexical IIFEs': `
namespace Outer { export namespace Inner { export let value = 1; } }
namespace Outer { export namespace Inner { export let next = value + 2; } }
console.log(JSON.stringify([Outer.Inner.value, Outer.Inner.next]));
`,
  'dotted merged namespace declarations share exact inner owner': `
namespace Outer.Inner { export let value = 1; }
namespace Outer.Inner { export let next = value + 2; }
console.log(JSON.stringify([Outer.Inner.value, Outer.Inner.next]));
`,
  'merged destructuring exports keep generated temps local': `
namespace N {
  const _a = 99;
  export const { value } = { value: 1 };
  export function local() { return _a; }
}
namespace N { export const next = value + 2; }
console.log(JSON.stringify([N.value, N.next, N.local()]));
`,
  'merged aliased and rest destructuring exports': `
namespace N {
  export const { x: alias, ...rest } = { x: 1, y: 4 };
}
namespace N { export const next = alias + rest.y; }
console.log(JSON.stringify([N.alias, N.rest.y, N.next]));
`,
  'merged nested and defaulted destructuring exports': `
namespace N {
  export const { nested: { x = 2 }, arr: [y] } = { nested: {}, arr: [3] };
}
namespace N { export const next = x + y; }
console.log(JSON.stringify([N.x, N.y, N.next]));
`,
  'empty exported patterns evaluate each initializer once': `
let objectCalls = 0;
let arrayCalls = 0;
function objectSource() { objectCalls++; return { ignored: 1 }; }
function arraySource() { arrayCalls++; return []; }
namespace N {
  export const {} = objectSource();
  export const [] = arraySource();
}
console.log(JSON.stringify([objectCalls, arrayCalls]));
`,
} as const;

function transpileReference(source: string): string {
  return ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2015, module: ts.ModuleKind.CommonJS },
  }).outputText;
}

describe('namespace binding provenance (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const [name, source] of Object.entries(cases)) {
    for (const target of ['es5', 'es2015', 'esnext']) {
      for (const bundled of [false, true]) {
        for (const minify of [false, true]) {
          test(`${name}: ${target}, ${bundled ? 'bundle' : 'single'}, ${minify ? 'minify' : 'plain'}`, async () => {
            const fixture = await createFixture({
              'input.ts': source,
              'reference.cjs': transpileReference(source),
            });
            cleanup = fixture.cleanup;
            const native = spawnSync('node', [join(fixture.dir, 'reference.cjs')], {
              encoding: 'utf8',
            });
            expect(native.status, native.stderr).toBe(0);
            const out = join(fixture.dir, bundled ? 'out.cjs' : 'out.mjs');
            const result = await runZntcInDir(fixture.dir, [
              ...(bundled ? ['--bundle', '--platform=node', '--format=cjs'] : []),
              '--target=' + target,
              ...(minify ? ['--minify'] : []),
              'input.ts',
              '-o',
              out,
            ]);
            expect(result.exitCode, result.stderr).toBe(0);
            const actual = spawnSync('node', [out], { encoding: 'utf8' });
            expect(actual.status, actual.stderr).toBe(0);
            expect(actual.stdout).toBe(native.stdout);
          });
        }
      }
    }
  }

  for (const minify of [false, true]) {
    test(`module namespace export remains one top-level binding, ${minify ? 'minify' : 'plain'}`, async () => {
      const lib = `export namespace N { export const value = 1; export function read() { return value; } }`;
      const entry = `import { N } from './lib'; console.log(JSON.stringify([N.value, N.read()]));`;
      const fixture = await createFixture({
        'lib.ts': lib,
        'entry.ts': entry,
        'lib.js': transpileReference(lib),
        'reference.cjs': transpileReference(entry),
      });
      cleanup = fixture.cleanup;
      const native = spawnSync('node', [join(fixture.dir, 'reference.cjs')], { encoding: 'utf8' });
      expect(native.status, native.stderr).toBe(0);
      const out = join(fixture.dir, 'out.cjs');
      const result = await runZntcInDir(fixture.dir, [
        '--bundle',
        '--platform=node',
        '--format=cjs',
        '--target=es5',
        ...(minify ? ['--minify'] : []),
        'entry.ts',
        '-o',
        out,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);
      const actual = spawnSync('node', [out], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe(native.stdout);
    });
  }

  for (const minify of [false, true]) {
    test(`cross-module merged namespace exports stay live, ${minify ? 'minify' : 'plain'}`, async () => {
      const lib = `export namespace N { export let value = 1; } export namespace N { export let next = value + 2; }`;
      const entry = `import { N } from './lib'; console.log(JSON.stringify([N.value, N.next]));`;
      const fixture = await createFixture({
        'lib.ts': lib,
        'entry.ts': entry,
        'lib.js': transpileReference(lib),
        'reference.cjs': transpileReference(entry),
      });
      cleanup = fixture.cleanup;
      const native = spawnSync('node', [join(fixture.dir, 'reference.cjs')], { encoding: 'utf8' });
      expect(native.status, native.stderr).toBe(0);
      const out = join(fixture.dir, 'out.cjs');
      const result = await runZntcInDir(fixture.dir, [
        '--bundle',
        '--platform=node',
        '--format=cjs',
        '--target=es5',
        ...(minify ? ['--minify'] : []),
        'entry.ts',
        '-o',
        out,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);
      const actual = spawnSync('node', [out], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe(native.stdout);
    });
  }
});
