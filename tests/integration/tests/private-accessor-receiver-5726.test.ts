import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5726: lowered private methods and accessors (es2021 and below)
//  - turned `this.#g++` / `[this.#g] = …` on an instance accessor into an
//    update/assignment of a call (`++__classPrivateMethodGet(…).call(this)`),
//  - evaluated a receiver twice (`__classPrivateMethodGet(f(), …).call(f())`),
//  - made `this.#g = v` / `this.#g += v` evaluate to the setter's return, and
//  - left `this.#g ||= v` as a SyntaxError.
// Node runs the sources natively for the expected output.
const cases: Record<string, string> = {
  'receivers run once': `let n = 0;
class A {
  #x = 0;
  #m() { return 1; }
  get #g() { return 2; }
  set #g(v) { this.v = v; }
  static t(f) {
    const r = [f().#m(), f().#g, f()?.#m(), f().#m\`t\`];
    f().#g = 5; f().#g += 1; f().#g++; [f().#g] = [7]; f().#x += 1; f().#x++; f().#x ??= 1; f().#g ||= 1;
    return r.join();
  }
}
const a = new A();
console.log(A.t(() => (n++, a)), n, a.v);
`,
  'accessor updates, destructuring and assignment values': `const r = [];
class A {
  #x = '1';
  get #g() { return this._g ?? 2; }
  set #g(v) { this._g = v; return 'ignored'; }
  static get #s() { return 3; }
  static set #s(v) {}
  t(o) {
    r.push(this.#x++, this.#x, this.#g++, this.#g, ++this.#g);
    [this.#g] = [7]; r.push(this.#g);
    ({ a: o.#g } = { a: 8 }); r.push(o.#g);
    r.push((this.#g = 5), (this.#g += 1), (this.#g ||= 9), (this.#g &&= 4), (this.#g ??= 0), (A.#s = 7), (A.#s += 1));
    return r.join();
  }
}
console.log(new A().t(new A()));
`,
  'inside generators and async functions': `const r = [];
class A {
  #x = '1';
  get #g() { return this._g ?? 2; }
  set #g(v) { this._g = v; }
  *gen(o) { r.push(this.#x++, this.#x); yield 1; r.push(o.#g++, o.#g, ++o.#g); }
  async run(o) { await null; o.#g += 10; r.push(o.#g); o.#g ??= 1; r.push((o.#g = 'z')); }
}
const a = new A();
[...a.gen(a)];
a.run(a).then(() => console.log(r.join()));
`,
};

describe('lowered private accessors and receivers (#5726)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const [name, source] of Object.entries(cases)) {
    for (const args of [
      ['--target=es2021'],
      ['--target=es2015', '--minify'],
      ['--target=es5'],
      ['--bundle', '--target=es5'],
    ]) {
      test(`${name}, ${args.join(' ')}`, async () => {
        const created = await createFixture({ 'entry.js': source });
        cleanup = created.cleanup;
        const expected = spawnSync('node', [join(created.dir, 'entry.js')], { encoding: 'utf8' });
        expect(expected.status, expected.stderr).toBe(0);
        const out = join(created.dir, 'out.cjs');
        const result = await runZntc([join(created.dir, 'entry.js'), ...args, '-o', out]);
        expect(result.exitCode, result.stderr).toBe(0);
        const run = spawnSync('node', [out], { encoding: 'utf8' });
        expect(run.status, run.stderr).toBe(0);
        expect(run.stdout).toBe(expected.stdout);
      });
    }
  }
});
