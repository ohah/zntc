import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5668 (1-3): lowering edge cases that changed run-time results. Node runs
// the sources natively for the expected output.
//  1. A top-level await nested in a block whose condition is a boolean
//     literal (`if (true) { await 0 }`) lost its `__async`/`__generator`
//     helpers in ES5 bundles: the import scanner's dead-branch ranges took a
//     generated branch spanning the whole program and dropped the prepended
//     helper imports.
//  2. `function g(a = 1) { var a; return a }` at es2015/es2017 renamed the
//     native parameter and left the body `var` undefined.
//  3. A lowered field initializer moved under a same-named constructor
//     binding read that binding (`f = x` with `var x` in the constructor).
const cases: Record<string, { file: string; source: string; args: string[][] }> = {
  'block top-level await keeps its helpers': {
    file: 'entry.mjs',
    source:
      "if (true) { await 0; }\nwhile (true) { await 0; break; }\ndo { await 0; } while (false);\nconsole.log('ok');",
    args: ['esm', 'iife', 'cjs'].map((f) => ['--bundle', `--format=${f}`, '--target=es5']),
  },
  'a body var named like a defaulted parameter': {
    file: 'entry.js',
    source:
      'function g(a = 1) { var a; return a; }\nfunction h({ ...r } = {}, a = 2) { var a; return [a, r]; }\nconsole.log(g(), JSON.stringify(h()));',
    args: ['es2017', 'es2015', 'es5'].flatMap((t) => [
      [`--target=${t}`],
      [`--target=${t}`, '--minify'],
    ]),
  },
  'field initializers keep outer bindings a constructor hides': {
    file: 'entry.js',
    source:
      'var x = "outer", y = "oy";\nfunction z() { return "oz"; }\nclass K {\n  f = x; g = () => y; h = z();\n  constructor(y) { var x = "ctor"; function z() { return "iz"; } this.r = [x, y, z()]; }\n}\nclass D extends K { k = x; constructor() { let x = "d"; super("p"); this.d = x; } }\nconst k = new K("py"), d = new D();\nconsole.log(JSON.stringify([k.f, k.g(), k.h, k.r, d.k, d.d, d.r]));\n',
    args: [
      ...['es2021', 'es2018', 'es2015', 'es5'].flatMap((t) => [
        [`--target=${t}`],
        [`--target=${t}`, '--minify'],
        ['--bundle', `--target=${t}`],
      ]),
      ['--target=esnext', '--use-define-for-class-fields=false'],
    ],
  },
};

describe('ES5/ES2015 lowering edge cases (#5668)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const [name, { file, source, args: argSets }] of Object.entries(cases)) {
    for (const args of argSets) {
      test(`${name}, ${args.join(' ')}`, async () => {
        const created = await createFixture({ [file]: source });
        cleanup = created.cleanup;
        const expected = spawnSync('node', [join(created.dir, file)], { encoding: 'utf8' });
        expect(expected.status, expected.stderr).toBe(0);
        const out = join(
          created.dir,
          file.endsWith('.mjs') && args.includes('--format=esm') ? 'out.mjs' : 'out.cjs',
        );
        const result = await runZntc([join(created.dir, file), ...args, '-o', out]);
        expect(result.exitCode, result.stderr).toBe(0);
        const run = spawnSync('node', [out], { encoding: 'utf8' });
        expect(run.status, run.stderr).toBe(0);
        expect(run.stdout).toBe(expected.stdout);
      });
    }
  }
});
