import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5575: without async functions (es2016 and lower) a top-level-await module
// is lowered to an async wrapper that the single-file ESM bundle awaits. The
// wrapper declared every binding after the first await, so an exported
// function reading one threw (`config is not defined`), and export
// declarations after the await stayed outside it and ran first (`b a c`).
// Like webpack's async module, the bindings are now declared ahead of the
// wrapper and everything after the first await runs inside it in source
// order. Node runs the sources natively for the expected output.
const cases: Record<string, { dep: string; entry: string }> = {
  'export declarations run in source order': {
    dep: "await 0;\nconsole.log('a');\nexport const y = (console.log('b'), 1);\nconsole.log('c', y);",
    entry: "import { y } from './dep.mjs';\nconsole.log('entry', y);",
  },
  'an exported function reads a binding declared after the await': {
    dep: 'const config = await Promise.resolve({ v: 7 });\nexport function f() { return config.v; }\nexport let counter = 0;\nexport function bump() { counter++; }',
    entry:
      "import { f, counter, bump } from './dep.mjs';\nbump();\nconsole.log('entry', f(), counter);",
  },
  'destructuring declarations and exports': {
    dep: 'const { a, b: [c] = [9], ...rest } = await Promise.resolve({ a: 1, z: 2 });\nexport const { d = 4, e } = { e: 5 };\nexport function get() { return [a, c, rest, d, e]; }',
    entry: "import { get } from './dep.mjs';\nconsole.log(JSON.stringify(get()));",
  },
  'classes declared after the await': {
    dep: 'const base = await Promise.resolve(10);\nclass Inner { v() { return base; } }\nexport class K { static s = 1; m() { return new Inner().v() + K.s; } }\nexport function make() { return new K().m(); }',
    entry: "import { make } from './dep.mjs';\nconsole.log(make());",
  },
  'a live binding assigned after the await': {
    dep: 'export let n = 0;\nn = await Promise.resolve(5);\nexport function inc() { n++; }',
    entry: "import { n, inc } from './dep.mjs';\nconsole.log(n); inc(); console.log(n);",
  },
  'a default export expression': {
    dep: "const v = await Promise.resolve(3);\nconsole.log('dep body');\nexport default v * 2;",
    entry: "import d from './dep.mjs';\nconsole.log('entry', d);",
  },
  'a default export next to a user _default': {
    dep: "const _default = 'user';\nawait 0;\nexport default _default + '!';",
    entry: "import d from './dep.mjs';\nconsole.log('entry', d);",
  },
  'inferred names of exported values': {
    dep: 'await 0;\nexport const fn = () => {};\nexport const fe = function () {};\nexport class Cls {}\nexport function get() { return [fn.name, fe.name, Cls.name]; }',
    entry: "import { get } from './dep.mjs';\nconsole.log(JSON.stringify(get()));",
  },
  'a function reading a nested var stays in the wrapper': {
    dep: "await 0;\nfor (var i = 0; i < 3; i++) {}\nfunction local() { return i; }\nconsole.log('inside', local());",
    entry: "import './dep.mjs';\nconsole.log('entry');",
  },
  'code before the await calls a function declared after it': {
    dep: 'export const x = helper();\nawait 0;\nfunction helper() { return 3; }',
    entry: "import { x } from './dep.mjs';\nconsole.log(x);",
  },
};

describe('a lowered top-level-await module runs in order inside its wrapper (#5575)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const target of ['es2016', 'es2015', 'es5']) {
    for (const minify of [false, true]) {
      for (const [name, { dep, entry }] of Object.entries(cases)) {
        // Minification renames the values whose `name` the case prints.
        if (minify && name === 'inferred names of exported values') continue;
        test(`${name}, ${target}${minify ? ', minify' : ''}`, async () => {
          const created = await createFixture({ 'dep.mjs': dep, 'entry.mjs': entry });
          cleanup = created.cleanup;
          const expected = spawnSync('node', [join(created.dir, 'entry.mjs')], {
            encoding: 'utf8',
          });
          expect(expected.status, expected.stderr).toBe(0);
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
          expect(run.stdout).toBe(expected.stdout);
        });
      }
    }
  }
});
