import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5608: in transform mode (no bundling) a JavaScript or Flow import is kept even
// when its bindings are unused — the import evaluates its module. Only TypeScript
// drops imports used solely as types. esbuild 0.27.7 transform and Babel give the
// expected output for every case below.
const dep = "console.log('dep');\nexport const x = 1, y = 2;\nexport default 3;";

const cases = {
  'unused named import': {
    'entry.js': "import { x } from './dep.js';\nconsole.log('main');",
    expected: 'dep\nmain\n',
  },
  'one unused named specifier next to a used one': {
    'entry.js': "import { x, y } from './dep.js';\nconsole.log('main', y);",
    expected: 'dep\nmain 2\n',
  },
  'unused named, default and namespace imports in JSX': {
    'entry.jsx':
      "import d, { x } from './dep.js';\nimport * as ns from './dep.js';\nconsole.log('main');",
    expected: 'dep\nmain\n',
  },
  'unused named import in a Flow file': {
    'entry.js':
      "// @flow\nimport { x } from './dep.js';\nimport type { T } from './dep.js';\nconst n: number = 1;\nconsole.log('main', n);",
    expected: 'dep\nmain 1\n',
  },
  'TypeScript still drops an unused import': {
    'entry.ts': "import { x } from './dep.js';\nconst n: number = 1;\nconsole.log('main', n);",
    expected: 'main 1\n',
  },
} as const;

describe('transform keeps unused JavaScript imports (#5608)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const [name, { expected, ...files }] of Object.entries(cases)) {
    test(name, async () => {
      const created = await createFixture({
        ...files,
        'dep.js': dep,
        'package.json': '{"type":"module"}',
      });
      cleanup = created.cleanup;
      const entry = Object.keys(files)[0]!;
      const out = join(created.dir, 'out.js');
      const result = await runZntc([join(created.dir, entry), '-o', out]);
      expect(result.exitCode, result.stderr).toBe(0);
      const run = spawnSync('node', [out], { encoding: 'utf8' });
      expect(run.status, run.stderr).toBe(0);
      expect(run.stdout).toBe(expected);
    });
  }
});
