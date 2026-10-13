import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5669: a Stage 3 decorator on a private auto-accessor (`@d accessor #a`)
// received `undefined` instead of the original `{ get, set }` pair, so it
// threw at class definition. Like tsc, the pair now goes through a descriptor
// (`_private_a_descriptor`) and `get #a` / `set #a` call what the decorators
// return. The ES5 class-expression lowering also branded an instance twice
// for a private getter/setter pair. Expected values are tsc's output run in
// Node, or Node itself for plain JavaScript.
const cases: Record<string, { file: string; source: string; expected: string }> = {
  'decorated private accessors': {
    file: 'entry.ts',
    source:
      "const log: any[] = [];\nfunction d(target: any, ctx: any) { log.push(ctx.kind + ':' + ctx.name + ':' + ctx.private); ctx.addInitializer(() => log.push('extra')); return { init: (v: any) => v * 10, get() { return target.get.call(this) + 1; }, set(v: any) { target.set.call(this, v); } }; }\nclass A { @d accessor #a = 1; @d static accessor #s = 2; get a() { return this.#a; } set a(v) { this.#a = v; } static get s() { return A.#s; } }\nconst o = new A(); o.a = 5;\nconsole.log(log.join(), o.a, A.s);\n",
    expected: 'accessor:#s:true,accessor:#a:true,extra,extra 6 21\n',
  },
  'a decorator that keeps the accessor': {
    file: 'entry.ts',
    source:
      'function d(target: any, ctx: any) {}\nclass A { @d accessor #a = 1; get a() { return this.#a; } set a(v) { this.#a = v; } }\nconst o = new A(); o.a = 3;\nconsole.log(o.a, new A().a);\n',
    expected: '3 1\n',
  },
  'a private getter/setter pair in a class expression': {
    file: 'entry.js',
    source:
      'const B = class { get #a() { return 1; } set #a(v) {} t() { return this.#a; } };\nconsole.log(new B().t());\n',
    expected: '1\n',
  },
};

describe('decorated private auto-accessors (#5669)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const [name, { file, source, expected }] of Object.entries(cases)) {
    for (const args of [
      ['--target=esnext'],
      ['--target=es2022', '--minify'],
      ['--target=es2021'],
      ['--target=es2015', '--minify'],
      ['--target=es5'],
      ['--bundle', '--target=es5'],
    ]) {
      test(`${name}, ${args.join(' ')}`, async () => {
        const created = await createFixture({ [file]: source });
        cleanup = created.cleanup;
        const out = join(created.dir, 'out.cjs');
        const result = await runZntc([join(created.dir, file), ...args, '-o', out]);
        expect(result.exitCode, result.stderr).toBe(0);
        const run = spawnSync('node', [out], { encoding: 'utf8' });
        expect(run.status, run.stderr).toBe(0);
        expect(run.stdout).toBe(expected);
      });
    }
  }
});
