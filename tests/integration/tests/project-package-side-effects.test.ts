import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5634: the nearest package.json `sideEffects` field also applies to code
// outside node_modules (the project itself, or a workspace package bundled
// from source). zntc only read it inside node_modules. esbuild 0.27.7 and
// rolldown print the expected output for every case.
const cases = {
  'bare import in a side-effect-free project': {
    'package.json': '{"sideEffects": false}',
    'entry.js': "import { used } from './lib.js'; console.log(used);",
    'lib.js': "import './side.js'; export const used = 1;",
    'side.js': "console.log('side');",
    expected: '1\n',
  },
  'sideEffects array': {
    'package.json': '{"sideEffects": ["./src/poly.js"]}',
    'entry.js': "import './src/poly.js'; import './src/other.js'; console.log('entry');",
    'src/poly.js': "console.log('poly');",
    'src/other.js': "console.log('other');",
    expected: 'poly\nentry\n',
  },
  'nested workspace package': {
    'package.json': '{}',
    'pkg/package.json': '{"sideEffects": false}',
    'entry.js': "import { u } from './pkg/a.js'; console.log(u);",
    'pkg/a.js': "import './b.js'; export const u = 1;",
    'pkg/b.js': "console.log('b');",
    expected: '1\n',
  },
  'unused CommonJS import in a side-effect-free project': {
    'package.json': '{"sideEffects": false}',
    'entry.js': "import { used } from './lib.js'; console.log(used());",
    'lib.js':
      "import * as cjslib from './cjslib.cjs'; export function used() { return 'used'; } export function heavy() { return cjslib.bar(); }",
    'cjslib.cjs': "console.log('cjs'); exports.bar = function () {};",
    expected: 'used\n',
  },
  'the entry keeps its own side effects': {
    'package.json': '{"sideEffects": false}',
    'entry.js': "console.log('entry'); import { v } from './dep.js'; console.log(v[0]);",
    'dep.js': "export const v = [1]; console.log('dep');",
    expected: 'dep\nentry\n1\n',
  },
} as const;

describe('package.json sideEffects applies outside node_modules (#5634)', () => {
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
          join(created.dir, 'entry.js'),
          '--format=esm',
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
});
