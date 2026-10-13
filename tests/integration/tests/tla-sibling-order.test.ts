import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5580: a module imported after a top-level-await module ran before it.
// Scope-hoisted code runs at the top level, ahead of the async init chain
// that starts the TLA module (`b1 a1 a2`). Modules after the first TLA module
// in evaluation order are now wrapped and initialized in import order. The
// expected output is esbuild 0.27.7 with `--target=es2022` (TLA kept), which
// is also zntc's es2022 order; native evaluation interleaves `b1` into the
// await (`a1 b1 a2`) and is not reproduced.
const a = "console.log('a1'); await 0; console.log('a2'); export const a = 1;";
const cases = {
  'sibling after a TLA module': {
    files: {
      'a.mjs': a,
      'b.mjs': "console.log('b1'); export const b = 2;",
      'entry.mjs':
        "import { a } from './a.mjs'; import { b } from './b.mjs'; console.log('entry', a, b);",
    },
    expected: 'a1\na2\nb1\nentry 1 2\n',
  },
  "sibling's own dependencies": {
    files: {
      'a.mjs': a,
      'b.mjs': "import { c } from './c.mjs'; console.log('b1', c[0]); export const b = 2;",
      'c.mjs': "console.log('c1'); export const c = [3];",
      'entry.mjs':
        "import { a } from './a.mjs'; import { b } from './b.mjs'; console.log('entry', a, b);",
    },
    expected: 'a1\na2\nc1\nb1 3\nentry 1 2\n',
  },
  'dependency shared with a module before the TLA module': {
    files: {
      'a.mjs': a,
      'x.mjs': "import { c } from './c.mjs'; console.log('x1', c[0]);",
      'b.mjs': "import { c } from './c.mjs'; console.log('b1', c[0]); export const b = 2;",
      'c.mjs': "console.log('c1'); export const c = [3];",
      'entry.mjs':
        "import './x.mjs'; import { a } from './a.mjs'; import { b } from './b.mjs'; console.log('entry', a, b);",
    },
    expected: 'c1\nx1 3\na1\na2\nb1 3\nentry 1 2\n',
  },
  'CommonJS sibling': {
    files: {
      'a.mjs': a,
      'c.cjs': "console.log('c1'); module.exports = { c: 3 };",
      'entry.mjs':
        "import { a } from './a.mjs'; import c from './c.cjs'; console.log('entry', a, c.c);",
    },
    expected: 'a1\na2\nc1\nentry 1 3\n',
  },
  'two TLA modules with siblings': {
    files: {
      'a.mjs': a,
      'b.mjs': "console.log('b1'); export const b = 2;",
      'e.mjs': "console.log('e1'); await 0; console.log('e2'); export const e = 5;",
      'f.mjs': "console.log('f1'); export const f = 6;",
      'entry.mjs':
        "import { b } from './b.mjs'; import { a } from './a.mjs'; import { f } from './f.mjs'; import { e } from './e.mjs'; console.log('entry', a, b, e, f);",
    },
    expected: 'b1\na1\na2\nf1\ne1\ne2\nentry 1 2 5 6\n',
  },
  'function, class, default and namespace exports of a sibling': {
    files: {
      'a.mjs': a,
      'b.mjs':
        "console.log('b1'); export function g() { return 7; } export class K { static v = 8; } export default 9;",
      'entry.mjs':
        "import { a } from './a.mjs'; import d, { g, K } from './b.mjs'; import * as ns from './b.mjs'; console.log('entry', a, g(), K.v, d, Object.keys(ns).sort().join());",
    },
    expected: 'a1\na2\nb1\nentry 1 7 8 9 K,default,g\n',
  },
} as const;

describe('modules after a top-level-await module keep import order (#5580)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const target of ['es2017', 'es2019', 'es2022']) {
    for (const minify of [false, true]) {
      for (const [name, { files, expected }] of Object.entries(cases)) {
        test(`${name}, ${target}${minify ? ', minify' : ''}`, async () => {
          const created = await createFixture(files);
          cleanup = created.cleanup;
          const out = join(created.dir, 'out.mjs');
          const result = await runZntc([
            '--bundle',
            join(created.dir, 'entry.mjs'),
            '--format=esm',
            `--target=${target}`,
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
