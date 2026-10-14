import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5821: es5 spread lowering passes an array literal straight to `concat`,
// which keeps holes, while spread reads through the iterator and fills them
// with undefined: `[...[, 1]]` came out as `[].concat([, 1])` and `0 in a` was
// false. Holes are filled with `void 0` like esbuild's minify-syntax does.
// Node runs the source natively for the expected output; the symbol gate must
// stay clean.
const source = `const r = [];
const k = (x) => Object.keys(x).join("") + "/" + x.length;
const a = [1, 2];
r.push(k([...[, 1]]), k([0, ...[, , 2], 3]), k([...[1, ,]]), k([...[...[, 1]]]));
r.push(k([, ...a]), k([, , ...[, 3], ,]));
let i = 0;
r.push(k([...[, i++, , i++]]), i);
r.push([...[, 1]].map((v) => typeof v).join(""));
function F() { this.n = arguments.length; this.h = 0 in arguments; }
const o = new F(...[, 1]);
r.push(o.n, o.h, Math.max(...[, 1]));
console.log(r.join(" "));
`;

describe('es5 spread fills array literal holes (#5821)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const extra of [[], ['--minify'], ['--bundle'], ['--bundle', '--minify']]) {
    test(`es5 ${extra.join(' ')}`, async () => {
      const created = await createFixture({ 'entry.js': source });
      cleanup = created.cleanup;
      const expected = spawnSync('node', [join(created.dir, 'entry.js')], { encoding: 'utf8' });
      expect(expected.status, expected.stderr).toBe(0);
      const out = join(created.dir, 'out.cjs');
      const result = await runZntc(
        [join(created.dir, 'entry.js'), '--target=es5', ...extra, '-o', out],
        { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
      );
      expect(result.exitCode, result.stderr).toBe(0);
      expect(result.stderr).not.toMatch(/clean=0/);
      const run = spawnSync('node', [out], { encoding: 'utf8' });
      expect(run.status, run.stderr).toBe(0);
      expect(run.stdout).toBe(expected.stdout);
    });
  }
});
