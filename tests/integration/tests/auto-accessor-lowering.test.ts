import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5695: an auto-accessor (`accessor a = 1`) was emitted as is for every
// target but ES5, and no engine runs that syntax yet (SyntaxError). Like
// esbuild, every target but esnext now lowers it to private storage with a
// getter and setter; a runtime computed key is evaluated once. Lowering a
// private getter/setter pair below es2022 also branded each instance twice
// ("Cannot initialize the same private elements twice"). Expected output is
// esbuild's (plain accessors) and tsc's (with decorators).
const cases: Record<string, { source: string; expected: string }> = {
  'plain auto-accessors': {
    source:
      "let n = 0;\nconst k = () => { n++; return 'c'; };\nclass A {\n  accessor a = 1;\n  static accessor s = 2;\n  accessor #p = 3;\n  accessor [k()] = 4;\n  get p() { return this.#p; }\n  set p(v) { this.#p = v; }\n}\nconst B = class { accessor b = 5; };\nconst x = new A(); x.a = 10; x.p = 30; x.c = 40;\nconsole.log(x.a, A.s, x.p, x.c, n, new B().b, Object.keys(x).length, typeof Object.getOwnPropertyDescriptor(A.prototype, 'a').get);\n",
    expected: '10 2 30 40 1 5 0 function\n',
  },
  'plain and decorated auto-accessors': {
    source:
      "function d(t, c) { return { get() { return t.get.call(this) * 2; } }; }\nfunction md(f) { return function () { return f.call(this) + '!'; }; }\nclass A { accessor plain = 1; @d accessor dec = 2; @md m() { return 'm'; } }\nconst a = new A(); a.plain = 7; console.log(a.plain, a.dec, a.m());\n",
    expected: '7 4 m!\n',
  },
  'a private getter/setter pair': {
    source:
      'class A { #s = 3; get #p() { return this.#s; } set #p(v) { this.#s = v; } get p() { return this.#p; } set p(v) { this.#p = v; } }\nconst a = new A(); a.p = 30; console.log(a.p);\n',
    expected: '30\n',
  },
};

describe('auto-accessors are lowered below esnext (#5695)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const target of ['es2024', 'es2022', 'es2021', 'es2015', 'es5']) {
    for (const mode of ['transform', 'minify', 'bundle']) {
      for (const [name, { source, expected }] of Object.entries(cases)) {
        test(`${name}, ${target}, ${mode}`, async () => {
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
  }
});
