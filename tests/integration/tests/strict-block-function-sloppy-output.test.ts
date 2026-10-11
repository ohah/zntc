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

  for (const fixture of cases) {
    for (const format of ['iife', 'cjs', 'umd', 'esm'] as const) {
      for (const minify of [false, true]) {
        test(`${fixture.name}, ${format}${minify ? ', minify' : ''}`, async () => {
          const created = await createFixture({
            ...fixture.files,
            'package.json': '{"type":"module"}',
          });
          cleanup = created.cleanup;
          const expected = nativeOutput(created.dir);
          const out = join(created.dir, format === 'esm' ? 'out.mjs' : 'out.cjs');
          const result = await runZntc([
            '--bundle',
            join(created.dir, 'entry.js'),
            `--format=${format}`,
            ...(minify ? ['--minify'] : []),
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
  }
});
