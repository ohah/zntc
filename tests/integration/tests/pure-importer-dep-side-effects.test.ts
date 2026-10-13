import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// A module with no side effects of its own still evaluates the modules it
// imports. Once constant propagation removed every use of its exports, the
// tree shaker dropped it and the side effects of its dependencies with it
// (`import { b } from './b'; export const m = b;` lost `b`'s console.log).
// An unused import binding inside an included module dropped its source the
// same way. esbuild 0.27.7, rolldown and Node print the expected output.
const cases = {
  'constant re-exported through a pure module': {
    'b.mjs': "console.log('b1'); export const b = 2;",
    'm.mjs': "import { b } from './b.mjs'; export const m = b;",
    'entry.mjs': "import { m } from './m.mjs'; console.log('entry', m);",
    expected: 'b1\nentry 2\n',
  },
  'global write in the dependency': {
    'b.mjs': 'globalThis.z = 9; export const b = 2;',
    'm.mjs': "import { b } from './b.mjs'; export const m = b + 1;",
    'entry.mjs': "import { m } from './m.mjs'; console.log('entry', m, globalThis.z);",
    expected: 'entry 3 9\n',
  },
  'two pure modules in a chain': {
    'c.mjs': "console.log('c1'); export const c = 3;",
    'b.mjs': "import { c } from './c.mjs'; export const b = c;",
    'm.mjs': "import { b } from './b.mjs'; export const m = b;",
    'entry.mjs': "import { m } from './m.mjs'; console.log('entry', m);",
    expected: 'c1\nentry 3\n',
  },
  'pure module importing two side-effectful modules': {
    'a.mjs': "console.log('a1'); export const a = 1;",
    'b.mjs': "console.log('b1'); export const b = 2;",
    'm.mjs': "import { a } from './a.mjs'; import { b } from './b.mjs'; export const m = a + b;",
    'entry.mjs': "import { m } from './m.mjs'; console.log('entry', m);",
    expected: 'a1\nb1\nentry 3\n',
  },
  'import used only in a dead function body': {
    'dep.mjs': "console.log('dep'); export function dep() { return 1; }",
    'side.mjs':
      "import { dep } from './dep.mjs'; console.log('side'); export function unused() { return dep(); }",
    'barrel.mjs': "export { used } from './live.mjs'; export { unused } from './side.mjs';",
    'live.mjs': "export const used = 'live';",
    'entry.mjs': "import { used } from './barrel.mjs'; console.log(used);",
    expected: 'dep\nside\nlive\n',
  },
  'pure dependency without side effects is still dropped': {
    'b.mjs': 'export const b = 2;',
    'm.mjs': "import { b } from './b.mjs'; export const m = b;",
    'entry.mjs': "import { m } from './m.mjs'; console.log('entry', m);",
    expected: 'entry 2\n',
  },
} as const;

describe('a pure module keeps its dependencies evaluated', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const minify of [false, true]) {
    for (const [name, { expected, ...files }] of Object.entries(cases)) {
      test(`${name}${minify ? ', minify' : ''}`, async () => {
        const created = await createFixture(files);
        cleanup = created.cleanup;
        const out = join(created.dir, 'out.mjs');
        const result = await runZntc([
          '--bundle',
          join(created.dir, 'entry.mjs'),
          '--format=esm',
          ...(minify ? ['--minify'] : []),
          '-o',
          out,
        ]);
        expect(result.exitCode, result.stderr).toBe(0);
        const run = spawnSync('node', [out], { encoding: 'utf8' });
        expect(run.status, run.stderr).toBe(0);
        expect(run.stdout).toBe(expected);
        if (name.includes('still dropped')) {
          expect(await Bun.file(out).text()).not.toContain('b.mjs');
        }
      });
    }
  }
});
