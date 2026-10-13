import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5666: a CommonJS module imported between ESM modules ran after them: the
// importer's `var c = require_c()` sat in the importer's region, after every
// scope-hoisted dependency. Node, esbuild and rolldown run it at its import
// position, so the bundle now calls `require_c();` right before the next
// hoisted module that runs after it. Node runs the sources natively for the
// expected output.
const cases: Record<string, Record<string, string>> = {
  'a default import between side-effect imports': {
    'main.mjs':
      "import './a.mjs'; import c from './c.cjs'; import './b.mjs'; console.log('main', c.v);",
    'a.mjs': "console.log('a1');",
    'b.mjs': "console.log('b1');",
    'c.cjs': "console.log('c'); module.exports = { v: 1 };",
  },
  'named, side-effect and nested imports': {
    'main.mjs':
      "import './a.mjs';\nimport { v } from './c.cjs';\nimport './d.cjs';\nimport './b.mjs';\nimport e from './e.cjs';\nimport './f.mjs';\nconsole.log('main', v, e);",
    'a.mjs': "import './c.cjs'; console.log('a1');",
    'b.mjs': "import './g.mjs'; import x from './h.cjs'; import './i.mjs'; console.log('b1', x);",
    'c.cjs': "console.log('c'); exports.v = 1;",
    'd.cjs': "console.log('d');",
    'e.cjs': "console.log('e'); module.exports = 'E';",
    'f.mjs': "console.log('f1');",
    'g.mjs': "console.log('g1');",
    'h.cjs': "console.log('h'); module.exports = 'H';",
    'i.mjs': "console.log('i1');",
  },
};

describe('CommonJS imports run at their import position (#5666)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const [name, files] of Object.entries(cases)) {
    for (const args of [
      ['--format=esm'],
      ['--format=esm', '--minify'],
      ['--format=cjs'],
      ['--format=iife', '--sourcemap'],
    ]) {
      test(`${name}, ${args.join(' ')}`, async () => {
        const created = await createFixture(files);
        cleanup = created.cleanup;
        const expected = spawnSync('node', [join(created.dir, 'main.mjs')], { encoding: 'utf8' });
        expect(expected.status, expected.stderr).toBe(0);
        const out = join(created.dir, args.includes('--format=esm') ? 'out.mjs' : 'out.cjs');
        const result = await runZntc([
          '--bundle',
          join(created.dir, 'main.mjs'),
          ...args,
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
});
