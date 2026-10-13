import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5664: export names that are not plain identifiers.
//  - A string literal name kept its source quotes: the namespace getter was
//    `get "'a-b'"()`, and `import { 'v' as w }` found no export `v`.
//  - `__proto__: () => …` in `__export` set the namespace's prototype instead
//    of defining the export.
//  - A user export named `__toESM` took the helper's name; the helper moved
//    to `__toESM$1` but a namespace import still called `__toESM`.
// Node runs the sources natively for the expected output.
const cases: Record<string, Record<string, string>> = {
  'string literal export name read through a namespace': {
    'q.mjs': "const x = 1;\nexport { x as 'a-b' };",
    'entry.mjs':
      "import * as ns from './q.mjs';\nconsole.log(ns['a-b'], JSON.stringify(Object.keys(ns)));",
  },
  'double-quoted export name imported with single quotes': {
    'q.mjs': 'const x = 1;\nexport { x as "a-b" };',
    'entry.mjs': "import { 'a-b' as y } from './q.mjs';\nconsole.log(y);",
  },
  'string import name of an identifier export': {
    'r.mjs': 'export const v = 7;',
    'entry.mjs': "import { 'v' as w } from './r.mjs';\nconsole.log(w);",
  },
  'string names in a re-export': {
    'r.mjs': 'export const v = 7;',
    'rr.mjs': "export { 'v' as 'x y' } from './r.mjs';",
    'entry.mjs':
      "import * as ns from './rr.mjs';\nimport { 'x y' as z } from './rr.mjs';\nconsole.log(ns['x y'], z);",
  },
  'export star as a string name': {
    'r.mjs': 'export const v = 7;',
    'rr.mjs': "export * as 'the ns' from './r.mjs';",
    'entry.mjs': "import * as ns from './rr.mjs';\nconsole.log(ns['the ns'].v);",
  },
  'an export named __proto__': {
    'p.mjs': 'const __proto__ = 1;\nexport { __proto__ };\nexport const b = 2;',
    'entry.mjs':
      "import('./p.mjs').then((m) => console.log(JSON.stringify(Object.keys(m)), m.__proto__ === 1));",
  },
  'a user export named after an interop helper': {
    't.mjs': 'await 0;\nexport const __toESM = 5;\nexport const __export = 6;',
    'c.cjs': 'module.exports = { v: 1 };',
    'entry.mjs':
      "import * as ns from './t.mjs';\nimport cj from './c.cjs';\nconsole.log(ns.__toESM, ns.__export, cj.v);",
  },
};

describe('export names keep one spelling across modules (#5664)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const format of ['esm', 'iife', 'cjs']) {
    for (const target of ['esnext', 'es2020', 'es5']) {
      for (const [name, files] of Object.entries(cases)) {
        // Top-level await needs ESM output (cjs/iife) or async functions (es5).
        if (
          name === 'a user export named after an interop helper' &&
          (format !== 'esm' || target === 'es5')
        )
          continue;
        test(`${name}, ${format}, ${target}`, async () => {
          const created = await createFixture(files);
          cleanup = created.cleanup;
          const expected = spawnSync('node', [join(created.dir, 'entry.mjs')], {
            encoding: 'utf8',
          });
          expect(expected.status, expected.stderr).toBe(0);
          const out = join(created.dir, format === 'cjs' ? 'out.cjs' : 'out.mjs');
          const result = await runZntc([
            '--bundle',
            join(created.dir, 'entry.mjs'),
            `--format=${format}`,
            `--target=${target}`,
            '-o',
            out,
          ]);
          expect(result.exitCode, result.stderr).toBe(0);
          const run = spawnSync('node', [out], { encoding: 'utf8' });
          expect(run.status, run.stderr).toBe(0);
          expect(run.stdout).toBe(expected.stdout);
        });
      }
    }
  }
});
