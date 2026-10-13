import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5633: module namespace object keys are sorted by code unit
// (ModuleNamespaceCreate), so `Object.keys(ns)`, `for…in` and
// `JSON.stringify` see them in that order. The bundled namespace objects
// (scope-hoisted getter literal and wrapped `__export`) used declaration order.
// The expected output is Node's (esbuild 0.27.7 agrees).
const dep = 'export function g() {} export class K {} export default 9; export const a = 1;';
const cases = {
  'scope-hoisted namespace': {
    'b.mjs': dep,
    'entry.mjs': "import * as ns from './b.mjs'; console.log(Object.keys(ns).join());",
    expected: 'K,a,default,g\n',
  },
  'namespace with export *': {
    'b.mjs': dep,
    'c.mjs': "export const Z = 1; export * from './b.mjs'; export const _ = 2;",
    'entry.mjs': "import * as ns from './c.mjs'; console.log(Object.keys(ns).join());",
    expected: 'K,Z,_,a,g\n',
  },
  'wrapped module after a top-level await': {
    't.mjs': 'await 0;',
    'b.mjs': dep,
    'entry.mjs':
      "import './t.mjs'; import * as ns from './b.mjs'; console.log(Object.keys(ns).join());",
    expected: 'K,a,default,g\n',
  },
  'dynamic import namespace': {
    'b.mjs': dep,
    'entry.mjs': "import('./b.mjs').then((ns) => console.log(Object.keys(ns).join()));",
    expected: 'K,a,default,g\n',
  },
  'for…in and JSON.stringify': {
    'b.mjs': 'export const z = 1, y = 2, x = 3;',
    'entry.mjs':
      "import * as ns from './b.mjs'; const k = []; for (const n in ns) k.push(n); console.log(k.join(), JSON.stringify(ns));",
    expected: 'x,y,z {"x":3,"y":2,"z":1}\n',
  },
} as const;

describe('bundled namespace objects list keys in sorted order (#5633)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const target of ['es2022', 'es2019']) {
    for (const minify of [false, true]) {
      for (const [name, { expected, ...files }] of Object.entries(cases)) {
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
