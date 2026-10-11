import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5454: ESM 소스(strict)의 블록 함수 선언은 블록 스코프다. 번들 출력이 `"use strict"`
// 없는 함수 안(iife/umd 스코프 호이스팅, `__esm` 래퍼)에 놓이면 Annex B 가 그 선언을
// 바깥 함수의 `var` 로 끌어올려 다른 모듈의 바인딩을 덮는다. 출력이 원래 소스의
// 의미를 따르는지(native ESM 결과와 같은지) 확인한다.
const cases = [
  {
    name: 'block function does not overwrite another module top-level function',
    files: {
      'a.js': `export function f() { return 'a'; }`,
      'b.js': `export function g() { { function f() { return 'b'; } } return 1; }
        { function f() { return 'b-top'; } }`,
      'entry.js': `import { f } from './a.js'; import { g } from './b.js'; g(); console.log(f());`,
    },
  },
  {
    name: 'block function called before its declaration inside the block',
    files: {
      'a.js': `export function f() { return 'a'; }`,
      'b.js': `export function g() { return 1; }
        { globalThis.early = f(); function f() { return 'b-block'; } }`,
      'entry.js': `import { f } from './a.js'; import { g } from './b.js'; g(); console.log(f(), globalThis.early);`,
    },
  },
  {
    name: 'block function shadowing an import inside a lazily initialized module',
    files: {
      'data.js': `export function f() { return 'outer'; }`,
      'box.js': `import { f } from './data.js';
        export const r = f();
        { function f() { return 'inner'; } globalThis.x = f(); }`,
      'entry.js': `import('./box.js').then((m) => console.log(m.r, globalThis.x));`,
    },
  },
  {
    name: 'block function next to an aliased import of the same name',
    files: {
      'a.js': `export function f() { return 'a'; }`,
      'b.js': `import { f as imported } from './a.js';
        export const before = imported();
        { function f() { return 'b-block'; } globalThis.blockResult = f(); }`,
      'entry.js': `import { f } from './a.js'; import { before } from './b.js';
        console.log(f(), before, globalThis.blockResult);`,
    },
  },
  {
    name: 'block-scoped let does not overwrite another module top-level function',
    files: {
      'a.js': `export function f() { return 'a'; }`,
      'b.js': `export function g() { return 1; }
        { let f = () => 'b-let'; globalThis.x = f(); }`,
      'entry.js': `import { f } from './a.js'; import { g } from './b.js'; g(); console.log(f(), globalThis.x);`,
    },
  },
  {
    name: 'switch case function does not overwrite another module top-level function',
    files: {
      'a.js': `export function f() { return 'a'; }`,
      'b.js': `export function g(k) {
          switch (k) { case 1: function f() { return 'b-case'; } return f(); }
          return 0;
        }
        switch (1) { case 1: function f() { return 'b-top'; } globalThis.x = f(); }`,
      'entry.js': `import { f } from './a.js'; import { g } from './b.js'; console.log(f(), g(1), globalThis.x);`,
    },
  },
  {
    // Switch-body functions exist on block entry, so a jump past the
    // declaring case can still call them (esbuild's in-place `let` throws here).
    name: 'switch case function is callable after jumping past its case',
    files: {
      'b.js': `export function g() {
          switch (2) { case 1: function f() { return 1; } case 2: return typeof f + ':' + f(); }
        }`,
      'entry.js': `import { g } from './b.js'; console.log(g());`,
    },
  },
  {
    // ES5 output renames the colliding block function; `.name` must still be
    // the source name, including on every switch entry that skips the case.
    name: 'renamed block function keeps its source name',
    files: {
      'a.js': `export function f() { return 'a'; }`,
      'b.js': `import { f } from './a.js';
        export const out = [f()];
        { function f() { return 'inner'; } out.push(f.name + ':' + f()); }
        for (const k of [1, 2]) {
          switch (k) { case 1: function f() { return 'case'; } case 2: out.push(f.name + ':' + f()); }
        }`,
      'entry.js': `import { out } from './b.js'; console.log(out.join());`,
    },
  },
  {
    // The discriminant reads the outer binding; the cases see the switch-body
    // function, even when the jump skips the declaring case.
    name: 'switch discriminant reads the name a case function shadows',
    files: {
      'a.js': `export function f() { return 'z'; }`,
      'b.js': `import { f } from './a.js';
        export const out = [];
        switch (f()) {
          case 'z': out.push(f.name + ':' + f()); break;
          case 'a': function f() { return 'inner'; }
        }`,
      'entry.js': `import { out } from './b.js'; console.log(out.join());`,
    },
  },
] as const;

function nativeOutput(dir: string): string {
  const native = spawnSync('node', [join(dir, 'entry.js')], { encoding: 'utf8', cwd: dir });
  expect(native.status, native.stderr).toBe(0);
  return native.stdout;
}

describe('strict block functions in sloppy bundle output (#5454)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  const variants = [
    ...(['iife', 'cjs', 'umd', 'esm'] as const).flatMap((format) =>
      [false, true].map((minify) => ({
        label: `${format}${minify ? ', minify' : ''}`,
        format,
        args: [`--format=${format}`, ...(minify ? ['--minify'] : [])],
      })),
    ),
    // ES5 targets cannot keep block functions block-scoped with `let`.
    ...(['iife', 'cjs', 'umd'] as const).map((format) => ({
      label: `${format}, es5`,
      format,
      args: [`--format=${format}`, '--target=es5'],
    })),
    {
      label: 'iife, es5, minify',
      format: 'iife' as const,
      args: ['--format=iife', '--target=es5', '--minify'],
    },
    {
      label: 'iife, es5, keep-names',
      format: 'iife' as const,
      args: ['--format=iife', '--target=es5', '--keep-names'],
    },
    { label: 'react-native', format: 'iife' as const, args: ['--platform=react-native'] },
  ];

  for (const fixture of cases) {
    for (const variant of variants) {
      test(`${fixture.name}, ${variant.label}`, async () => {
        const created = await createFixture({
          ...fixture.files,
          'package.json': '{"type":"module"}',
        });
        cleanup = created.cleanup;
        const expected = nativeOutput(created.dir);
        const out = join(created.dir, variant.format === 'esm' ? 'out.mjs' : 'out.cjs');
        const result = await runZntc([
          '--bundle',
          join(created.dir, 'entry.js'),
          ...variant.args,
          '-o',
          out,
        ]);
        expect(result.exitCode, result.stderr).toBe(0);
        const run = spawnSync('node', [out], { encoding: 'utf8' });
        expect(run.status, run.stderr).toBe(0);
        expect(run.stdout).toBe(expected);
      });
    }
  }
});
