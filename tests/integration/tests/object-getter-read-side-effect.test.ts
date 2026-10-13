import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5665: tree shaking treated every property read as pure, so an unused
// `export const x = o.p` dropped the call of `o`'s getter. Like rollup, a read
// of an object literal with a getter — written in place or bound at the module
// top level — now counts as a side effect; reads of plain objects are still
// removed. Node runs the sources natively for the expected output.
const files = {
  'g.mjs': "const o = { get p() { console.log('getter'); return 1; } };\nexport const x = o.p;",
  'g2.mjs':
    "export const o = { get p() { console.log('getter2'); return 1; } };\nexport const y = (o).p;\nconst z = ({ get q() { console.log('getter3'); return 2; } }).q;\nconst plain = { a: 1 };\nexport const w = plain.removedPlainRead;",
  'entry.mjs': "import { x } from './g.mjs';\nimport { w } from './g2.mjs';\nconsole.log('main');",
};

describe('reading an object getter is a side effect (#5665)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const args of [[], ['--minify'], ['--format=esm'], ['--target=es5']]) {
    test(`${args.join(' ') || 'default'}`, async () => {
      const created = await createFixture(files);
      cleanup = created.cleanup;
      const expected = spawnSync('node', [join(created.dir, 'entry.mjs')], { encoding: 'utf8' });
      expect(expected.status, expected.stderr).toBe(0);
      const out = join(created.dir, 'out.mjs');
      const result = await runZntc([
        '--bundle',
        join(created.dir, 'entry.mjs'),
        ...args,
        '-o',
        out,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);
      const run = spawnSync('node', [out], { encoding: 'utf8' });
      expect(run.status, run.stderr).toBe(0);
      expect(run.stdout).toBe(expected.stdout);
      // A read of an object without a getter is still dropped.
      expect(readFileSync(out, 'utf8')).not.toContain('removedPlainRead');
    });
  }
});
