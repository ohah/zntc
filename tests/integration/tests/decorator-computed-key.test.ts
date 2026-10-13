import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5669: a decorated class member with a runtime computed key (`@dec [k('m')]()`)
// panicked in every target — the decorator context read the key expression as
// a string literal. The key is now evaluated once, in place, into a temp
// (`[_a = __toPropertyKey(k('m'))]`), and the context name and access
// functions read the temp. Two decorated computed fields also collided on one
// `__initializers` local. Expected output is tsc's (ES2022 decorator
// lowering); esbuild keeps the raw key object, so its `toString` runs again.
const source = `const log = [];
function dec(v, ctx) { log.push(ctx.kind + ':' + String(ctx.name) + ':' + ctx.access.has({ [ctx.name]: 1 })); }
let n = 0;
const k = (s) => { n++; return s; };
const key = { toString() { n++; return 'o'; } };
const sym = Symbol('s');
class A {
  @dec [k('m')]() { return 'm'; }
  @dec [k('f')] = 1;
  @dec [k('h')] = 2;
  @dec get [k('g')]() { return 'g'; }
  @dec [key]() { return 'o'; }
  @dec [1 + 1]() { return 2; }
  @dec static [sym]() { return 's'; }
}
const a = new A();
console.log(log.join(), n, a.m(), a.f, a.h, a.g, a.o(), a[2](), A[sym]());`;
const expected =
  'method:Symbol(s):true,method:m:true,getter:g:true,method:o:true,method:2:true,field:f:true,field:h:true 5 m 1 2 g o 2 s\n';

describe('decorated members with runtime computed keys (#5669)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const target of ['esnext', 'es2022', 'es2021', 'es2015', 'es5']) {
    for (const mode of ['transform', 'minify', 'bundle']) {
      test(`${target}, ${mode}`, async () => {
        const created = await createFixture({ 'entry.js': source });
        cleanup = created.cleanup;
        const out = join(created.dir, 'out.js');
        const args = mode === 'bundle' ? ['--bundle'] : mode === 'minify' ? ['--minify'] : [];
        const result = await runZntc([
          ...args,
          join(created.dir, 'entry.js'),
          `--target=${target}`,
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
