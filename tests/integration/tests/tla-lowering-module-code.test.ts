import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5558 / #5562: lowering top-level await wraps the module body in an async IIFE whose
// promise `var _b = (async () => …)()` the `__esm` factory returns. A temp
// hoisted to the top level was merged into that declaration
// (`var _a, _b = …`), the emitter lost the promise binding, and the module
// body vanished from the bundle while the build still succeeded.
const cases = {
  'optional chain in an awaited expression': `const a = { c: { b: 1 } };
console.log(await Promise.resolve(a.c?.b));`,
  'temps from parameter initializers': `const a = { c: { b: 2 } };
const f = (y = a.c?.b) => y;
function g(y = a.c?.b ?? 0) { return y; }
console.log(await Promise.resolve(f() + g()));`,
  'exported binding initialized by await': `const a = { c: null };
export const v = await Promise.resolve(a.c?.b ?? 'fallback');
console.log(v);`,
  // #5562: the moved statements' scopes stayed under the program scope, so an
  // arrow parameter initializer lost the wrapped declarations it reads.
  'arrow parameter initializers reading wrapped bindings': `const a = 2;
const b = a;
const f = (y = a) => y;
{ let k = { c: 3 }; var g = (z = k) => z.c; }
console.log(await Promise.resolve(f()), b, g());`,
  'temps before and after the first await': `const a = { c: { b: 'x' } }, n = null;
const before = n?.y ?? a.c?.b;
const after = await Promise.resolve(n?.z ?? before);
console.log(before, after);`,
} as const;

describe('top-level await lowering keeps module code (#5558, #5562)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const [name, source] of Object.entries(cases)) {
    for (const args of [
      ['--target=es2019'],
      ['--target=es2017'],
      ['--target=es2019', '--minify'],
    ]) {
      test(`${name}, ${args.join(' ')}`, async () => {
        const created = await createFixture({ 'entry.mjs': source });
        cleanup = created.cleanup;
        const native = spawnSync('node', [join(created.dir, 'entry.mjs')], { encoding: 'utf8' });
        expect(native.status, native.stderr).toBe(0);
        const out = join(created.dir, 'out.mjs');
        const result = await runZntc([
          '--bundle',
          join(created.dir, 'entry.mjs'),
          '--format=esm',
          ...args,
          '-o',
          out,
        ]);
        expect(result.exitCode, result.stderr).toBe(0);
        const run = spawnSync('node', [out], { encoding: 'utf8' });
        expect(run.status, run.stderr).toBe(0);
        expect(run.stdout).toBe(native.stdout);
      });
    }
  }
});
