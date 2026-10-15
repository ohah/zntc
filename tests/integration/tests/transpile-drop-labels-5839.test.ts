import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { transpile } from '../../../packages/core/index';
import { createFixture, runZntc, ZNTC_JS_CLI } from './helpers';

// #5839: `--drop-labels` only worked with `--bundle`. The transpile options had
// no `drop_labels` field, so the Zig CLI, the JSON options DTO, `transpile()`
// and the JS CLI never reached the transformer, and single-file transpile kept
// every labeled statement. esbuild applies it to transform and bundle alike.
const source = `DEV: console.log("dev");
TEST: { console.log("test"); }
KEEP: { console.log("keep"); }
function f() { DEV: for (;;) { break DEV; } return "f"; }
console.log(f(), "end");
`;

describe('--drop-labels in single-file transpile (#5839)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const extra of [[], ['--minify'], ['--target=es5'], ['--bundle']]) {
    test(`zntc --drop-labels=DEV,TEST ${extra.join(' ')}`, async () => {
      const created = await createFixture({ 'entry.js': source });
      cleanup = created.cleanup;
      const out = join(created.dir, 'out.cjs');
      const result = await runZntc([
        join(created.dir, 'entry.js'),
        '--drop-labels=DEV,TEST',
        ...extra,
        '-o',
        out,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);
      const run = spawnSync('node', [out], { encoding: 'utf8' });
      expect(run.status, run.stderr).toBe(0);
      expect(run.stdout).toBe('keep\nf end\n');
    });
  }

  test('JS CLI --drop-labels=DEV,TEST', async () => {
    const created = await createFixture({ 'entry.js': source });
    cleanup = created.cleanup;
    const out = join(created.dir, 'out.cjs');
    const result = spawnSync(
      'bun',
      [ZNTC_JS_CLI, join(created.dir, 'entry.js'), '--drop-labels=DEV,TEST', '-o', out],
      { encoding: 'utf8' },
    );
    expect(result.status, result.stderr).toBe(0);
    const run = spawnSync('node', [out], { encoding: 'utf8' });
    expect(run.status, run.stderr).toBe(0);
    expect(run.stdout).toBe('keep\nf end\n');
  });

  test('transpile() dropLabels option', () => {
    const { code } = transpile(source, { filename: 'entry.js', dropLabels: ['DEV', 'TEST'] });
    expect(code).not.toContain('dev');
    expect(code).not.toContain('test');
    expect(code).toContain('keep');
  });
});
