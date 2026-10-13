import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5712: Stage 3 decorators on static members never ran the initializers
// they registered with `context.addInitializer`. tsc chains them like the
// instance ones: a static field first runs the pending extra initializers
// (static method decorators', then the previous decorated field's), and a
// static block or the class end runs them in `static { __runInitializers }`.
// Class decorator extra initializers run last, once every static element ran.
// A decorated auto-accessor without an initializer also skipped `init`.
// Expected values are tsc's output run in Node.
const header =
  "const log: any[] = [];\nfunction dec(tag: string) { return (target: any, ctx: any) => { ctx.addInitializer(function (this: any) { log.push('extra:' + tag); }); }; }\n";
const cases: Record<string, { source: string; expected: string }> = {
  'static fields, accessors, private fields and blocks': {
    source:
      "class A {\n  @dec('f') static f = log.push('f');\n  @dec('a') static accessor a = log.push('a');\n  @dec('p') static #p = log.push('p');\n  @dec('m') static m() {}\n  static { log.push('block'); }\n  @dec('g') static g = log.push('g');\n}\nconsole.log(log.join());\n",
    expected: 'extra:m,f,extra:f,a,extra:a,p,extra:p,block,g,extra:g\n',
  },
  'undecorated static fields take the pending extra initializers': {
    source:
      "class A { @dec('m') static m() {} static x = log.push('x'); @dec('f') static f = log.push('f'); static y = log.push('y'); }\nconsole.log(log.join());\n",
    expected: 'extra:m,x,f,extra:f,y\n',
  },
  'a static method decorator alone': {
    source: "class A { @dec('m') static m() {} }\nconsole.log(log.join());\n",
    expected: 'extra:m\n',
  },
  'class decorator extra initializers run last': {
    source:
      "@dec('C') class A {\n  @dec('pm') static #m() { return 1; }\n  @dec('f') static f = log.push('f');\n  static { log.push('block'); }\n  @dec('a') static accessor a;\n  static get m() { return A.#m(); }\n}\nconst B = class { @dec('bf') static f = log.push('bf'); @dec('bm') static m() {} };\nconsole.log(log.join(), A.m, A.a, B.f);\n",
    expected: 'extra:pm,f,extra:f,block,extra:a,extra:C,extra:bm,bf,extra:bf 1 undefined 8\n',
  },
  'accessor init without an initializer': {
    source:
      'function add(t: any, ctx: any) { return { init: (v: any) => (v ?? 0) + 5 }; }\nclass A { @add accessor x; @add static accessor y; }\nconsole.log(new A().x, A.y);\n',
    expected: '5 5\n',
  },
};

describe('Stage 3 static member extra initializers (#5712)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const [name, { source, expected }] of Object.entries(cases)) {
    for (const args of [
      ['--target=esnext'],
      ['--target=es2022'],
      ['--target=es2021', '--minify'],
      ['--target=es5'],
      ['--bundle', '--target=es2015'],
    ]) {
      test(`${name}, ${args.join(' ')}`, async () => {
        const created = await createFixture({ 'entry.ts': header + source });
        cleanup = created.cleanup;
        const out = join(created.dir, 'out.cjs');
        const result = await runZntc([join(created.dir, 'entry.ts'), ...args, '-o', out]);
        expect(result.exitCode, result.stderr).toBe(0);
        const run = spawnSync('node', [out], { encoding: 'utf8' });
        expect(run.status, run.stderr).toBe(0);
        expect(run.stdout).toBe(expected);
      });
    }
  }
});
