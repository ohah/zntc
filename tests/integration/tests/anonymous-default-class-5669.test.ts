import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5669 (1, 2): anonymous `export default class`.
//  1. ES5 lowering visited a static block before naming the inner
//     constructor, so its `this` became the outer `_Class` binding, still
//     undefined while the class IIFE runs (TypeError on import).
//  2. A decorated anonymous default class was named `_Class` (its wrapper
//     variable) instead of "default", in `.name` and the decorator's
//     `ctx.name`. tsc prints "default default".
const cases: Record<string, { source: string; entry: string; expected: string }> = {
  'static block and static members': {
    source:
      'export default class { static x = 1; static { this.y = this.x + 1; } static m() { return this.y; } }',
    entry: "import C from './out.mjs';\nconsole.log(C.x, C.y, C.m(), C.name);",
    expected: '1 2 2 default\n',
  },
  'decorated class name': {
    source: 'function d(c, ctx) { console.log(ctx.name); }\nexport default @d class {}',
    entry: "import C from './out.mjs';\nconsole.log(C.name);",
    expected: 'default\ndefault\n',
  },
};

describe('anonymous default-exported classes (#5669)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const [name, { source, entry, expected }] of Object.entries(cases)) {
    for (const target of ['esnext', 'es2022', 'es2021', 'es2015', 'es5']) {
      // Node runs `static {}` natively, so the source itself is the reference
      // only without decorators.
      for (const minify of [false, true]) {
        test(`${name}, ${target}${minify ? ', minify' : ''}`, async () => {
          const created = await createFixture({ 'src.mjs': source, 'main.mjs': entry });
          cleanup = created.cleanup;
          const result = await runZntc([
            join(created.dir, 'src.mjs'),
            `--target=${target}`,
            ...(minify ? ['--minify'] : []),
            '-o',
            join(created.dir, 'out.mjs'),
          ]);
          expect(result.exitCode, result.stderr).toBe(0);
          const run = spawnSync('node', [join(created.dir, 'main.mjs')], { encoding: 'utf8' });
          expect(run.status, run.stderr).toBe(0);
          expect(run.stdout).toBe(expected);
        });
      }
    }
  }
});
