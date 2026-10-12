import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// Block scoping lowering renames an inner `let`/`const`; an object shorthand
// `{ d }` then reads the renamed binding. Its implied read must keep the
// source reference's scope: inside a lowered async function it used to be
// re-created in the generator scope and aborted with `InvalidScope`.
const source = `const d = 'outer';
async function run() {
  { const d = 'inner'; console.log(JSON.stringify({ d })); }
  { let d = 'let'; const f = () => ({ d }); console.log(JSON.stringify(f())); }
  for (const d of ['loop']) console.log(JSON.stringify({ d }));
  console.log(JSON.stringify({ d }));
}
const gen = function* () { { const d = 'gen'; yield { d }; } };
run().then(() => console.log(JSON.stringify(gen().next().value)));`;

describe('block-renamed object shorthand', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const args of [
    ['--platform=react-native'],
    ['--platform=react-native', '--minify'],
    ['--target=es5'],
    ['--target=es2016'],
  ]) {
    test(args.join(' '), async () => {
      const created = await createFixture({
        'entry.js': source,
        'package.json': '{"type":"module"}',
      });
      cleanup = created.cleanup;
      const native = spawnSync('node', [join(created.dir, 'entry.js')], { encoding: 'utf8' });
      expect(native.status, native.stderr).toBe(0);
      const out = join(created.dir, 'out.cjs');
      const result = await runZntc([
        '--bundle',
        join(created.dir, 'entry.js'),
        '--format=iife',
        ...args,
        '-o',
        out,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);
      const run = spawnSync('node', [out], { encoding: 'utf8' });
      expect(run.status, run.stderr).toBe(0);
      expect(run.stdout).toBe(native.stdout);
    });
  }
});
