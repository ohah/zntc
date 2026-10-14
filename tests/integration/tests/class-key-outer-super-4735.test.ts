import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #4735: a class member's computed key is evaluated outside the class, so a
// `super` (or `this`, `arguments`) in it refers to the enclosing method, not
// to the class being defined. The key was visited inside the class's own
// super context: es5 read the inner class's parent (`undefined`), and es2015
// left a native `super` in an async body moved into a generator
// (SyntaxError). es5 also evaluated keys inside the class IIFE, where `this`
// and `_super` belong to the IIFE. A static block's nested class declaration
// leaked to the top of the module at es5. Node runs the source natively for
// the expected output; the symbol gate must stay clean.
const source = `const r = [];
const names = (C) => Object.getOwnPropertyNames(C.prototype).filter((n) => n !== "constructor").join("/");
class X {}
class A { get k() { return "Q" + this.tag; } f() { return "F" + this.tag; } static get s() { return "S"; } }
class B extends A {
  static t = "T";
  constructor() { super(); this.tag = "b"; class C { [super.k]() {} } r.push("ctor:" + names(C)); }
  static sm() { class C { [super.s]() {} } return names(C); }
  fk() { class C { [super.k] = 1; } return Object.keys(new C()).join(); }
  ar() { class C { [(() => super.k)()]() {} } return names(C); }
  call() { class C extends X { [super.f()]() {} } return names(C); }
  ce() { const C = class extends X { [super.k]() {} }; return names(C); }
  th() { class C { [this.tag]() {} } return names(C); }
  static { class C { [super.s + this.t]() {} } r.push("sb:" + names(C)); }
  async am() { await 0; class C { [super.k]() {} } return names(C); }
}
function g() { class C { [arguments[0]]() {} } return names(C); }
const o = {
  __proto__: { k: "P" },
  m() { return Object.keys({ [super.k]() {} }).join(); },
  async n() { class C extends X { [super.k]() {} } return names(C); },
  async *gen() { yield 0; class C { [super.k]() {} } yield names(C); },
};
const b = new B();
r.push(B.sm(), b.fk(), b.ar(), b.call(), b.ce(), b.th(), g("G"), o.m());
(async () => {
  r.push(await b.am(), await o.n());
  for await (const v of o.gen()) r.push(v);
  console.log(r.join());
})();
`;

describe('class computed keys see the outer super (#4735)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const target of ['es5', 'es2015', 'es2016', 'es2017', 'es2021', 'es2022']) {
    for (const extra of [[], ['--minify']]) {
      test(`${target} ${extra.join(' ')}`, async () => {
        const created = await createFixture({ 'entry.js': source });
        cleanup = created.cleanup;
        const expected = spawnSync('node', [join(created.dir, 'entry.js')], { encoding: 'utf8' });
        expect(expected.status, expected.stderr).toBe(0);
        const out = join(created.dir, 'out.cjs');
        const result = await runZntc(
          [join(created.dir, 'entry.js'), `--target=${target}`, ...extra, '-o', out],
          { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
        );
        expect(result.exitCode, result.stderr).toBe(0);
        expect(result.stderr).not.toMatch(/clean=0/);
        expect(result.stderr).toMatch(/clean=1/);
        // The post-minify gate once crashed on a freed class-self map here (#5757).
        if (extra.length > 0)
          expect(result.stderr).toMatch(/symbol-identity-post-minify .*clean=1/);
        const run = spawnSync('node', [out], { encoding: 'utf8' });
        expect(run.status, run.stderr).toBe(0);
        expect(run.stdout).toBe(expected.stdout);
      });
    }
  }
});
