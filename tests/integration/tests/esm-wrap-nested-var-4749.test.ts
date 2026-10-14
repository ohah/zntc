import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #4749: a module wrapped in `__esm` (React Native, or reached through
// `require`) hoisted only its top-level `var`s out of the factory. A `var`
// declared inside a top-level block (`if`, `try`, a loop head, `switch`, a
// label) stayed a factory-local `var`, so an export of it threw
// ReferenceError (or leaked a sloppy global). Like esbuild, those `var`s are
// hoisted too and written as assignments. Node runs the sources natively for
// the expected output.
const lib = `if (globalThis) { var k = 1; }
try { var j = 2; } finally {}
for (var i = 0, n = 2; i < n; i++) {}
for (var p in { q: 1 }) {}
for (var [x, y] of [[3, 4]]) {}
if (!globalThis) var z; else var w = 'w';
label: { var { a, ...rest } = { a: 5, b: 6 }; }
switch (1) { case 1: var s = 's'; }
function f() { if (1) { var inner = 'fn'; } return inner; }
export { k, j, i, n, p, x, y, z, w, a, rest, s, f };
`;

describe('__esm wrapper hoists block-nested var (#4749)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  const cases: [string, string, string[]][] = [
    [
      'main.mjs',
      "import * as m from './lib.mjs';\nconsole.log(JSON.stringify(m), m.z, m.f());\n",
      ['--platform=react-native'],
    ],
    [
      'main.mjs',
      "import * as m from './lib.mjs';\nconsole.log(JSON.stringify(m), m.z, m.f());\n",
      ['--platform=react-native', '--minify'],
    ],
    [
      'main.mjs',
      "import * as m from './lib.mjs';\nconsole.log(JSON.stringify(m), m.z, m.f());\n",
      ['--platform=react-native', '--target=es5'],
    ],
    [
      'main.cjs',
      "'use strict';\nconst m = require('./lib.mjs');\nconsole.log(JSON.stringify(m), m.z, m.f());\n",
      ['--format=cjs'],
    ],
    [
      'main.cjs',
      "'use strict';\nconst m = require('./lib.mjs');\nconsole.log(JSON.stringify(m), m.z, m.f());\n",
      ['--format=cjs', '--minify'],
    ],
  ];

  for (const [entry, source, args] of cases) {
    test(`${entry} ${args.join(' ')}`, async () => {
      const created = await createFixture({ 'lib.mjs': lib, [entry]: source });
      cleanup = created.cleanup;
      const expected = spawnSync('node', [join(created.dir, entry)], { encoding: 'utf8' });
      expect(expected.status, expected.stderr).toBe(0);
      const out = join(created.dir, 'out.js');
      const result = await runZntc(['--bundle', join(created.dir, entry), ...args, '-o', out]);
      expect(result.exitCode, result.stderr).toBe(0);
      const run = spawnSync('node', [out], { encoding: 'utf8' });
      expect(run.status, run.stderr).toBe(0);
      expect(run.stdout).toBe(expected.stdout);
    });
  }
});
