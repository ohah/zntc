import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5670: `export default function () {}` is a function declaration, hoisted
// like any other: a module in an import cycle may call it before the
// declaring module runs. The bundle emitted `var _default = function () {}`,
// initialized in place, so the cycle read `undefined`. Node runs the sources
// natively for the expected output.
const cases: Record<string, Record<string, string>> = {
  'anonymous default function': {
    'a.mjs': "import './b.mjs';\nexport default function () { return 'dflt'; }",
    'b.mjs': "import f from './a.mjs';\nconsole.log(f());",
  },
  'anonymous async default function': {
    'a.mjs': "import './b.mjs';\nexport default async function () { return 'async'; }",
    'b.mjs': "import f from './a.mjs';\nf().then((v) => console.log(v));",
  },
  'anonymous default generator': {
    'a.mjs': "import './b.mjs';\nexport default function* () { yield 'gen'; }",
    'b.mjs': "import f from './a.mjs';\nconsole.log(f().next().value);",
  },
  'default function read through a namespace': {
    'a.mjs': "import './b.mjs';\nexport default function () { return 'ns'; }",
    'b.mjs': "import * as a from './a.mjs';\nconsole.log(a.default());",
  },
};

describe('anonymous default-exported functions are hoisted in bundles (#5670)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  const modes: { label: string; args: string[] }[] = [
    { label: 'iife', args: [] },
    { label: 'esm', args: ['--format=esm'] },
    { label: 'cjs', args: ['--format=cjs'] },
    { label: 'es5', args: ['--target=es5'] },
    { label: 'minify, keep names', args: ['--minify', '--keep-names'] },
  ];
  for (const { label, args } of modes) {
    for (const [name, files] of Object.entries(cases)) {
      test(`${name}, ${label}`, async () => {
        const created = await createFixture(files);
        cleanup = created.cleanup;
        const expected = spawnSync('node', [join(created.dir, 'a.mjs')], { encoding: 'utf8' });
        expect(expected.status, expected.stderr).toBe(0);
        const out = join(created.dir, args.includes('--format=esm') ? 'out.mjs' : 'out.js');
        const result = await runZntc(['--bundle', join(created.dir, 'a.mjs'), ...args, '-o', out]);
        expect(result.exitCode, result.stderr).toBe(0);
        const run = spawnSync('node', [out], { encoding: 'utf8' });
        expect(run.status, run.stderr).toBe(0);
        expect(run.stdout).toBe(expected.stdout);
      });
    }
  }
});
