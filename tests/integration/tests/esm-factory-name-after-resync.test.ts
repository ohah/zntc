import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5629: a post-link semantic refresh (constant materialization dropping the
// `const k2 = k` binding) renumbers a module's symbols. The linker kept the
// `__esm` factory's old SymbolID, whose row now belonged to a helper-local, so
// the runtime helper was declared as `var fn = …` while every call site still
// read `__esm(…)`: ReferenceError at load. Node prints the expected output.
const dep = 'export const k = 5;';
const cases = {
  'dropped local alias of an imported constant': {
    'dep.mjs': dep,
    'entry.mjs':
      "import { k } from './dep.mjs';\nfunction f() { const k2 = k; return k2; }\nawait 0;\nconsole.log(f());",
    expected: '5\n',
  },
  'alias read twice': {
    'dep.mjs': dep,
    'entry.mjs':
      "import { k } from './dep.mjs';\nfunction f() { const k2 = k; return k2 + k; }\nawait 0;\nconsole.log(f());",
    expected: '10\n',
  },
  'alias in a module imported by the TLA entry': {
    'dep.mjs': dep,
    'mid.mjs': "import { k } from './dep.mjs';\nexport function f() { const k2 = k; return k2; }",
    'entry.mjs': "import { f } from './mid.mjs';\nawait 0;\nconsole.log(f());",
    expected: '5\n',
  },
} as const;

describe('ESM factory helper keeps its name after a semantic refresh (#5629)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const target of ['es2019', 'es2017']) {
    for (const minify of [false, true]) {
      for (const [name, { expected, ...files }] of Object.entries(cases)) {
        test(`${name}, ${target}${minify ? ', minify' : ''}`, async () => {
          const created = await createFixture(files);
          cleanup = created.cleanup;
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
          expect(run.stdout).toBe(expected);
        });
      }
    }
  }
});
