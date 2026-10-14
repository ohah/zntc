import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5822: codegen printed nothing for an elision and only wrote separators
// between elements, so a hole at the end of an array literal or array pattern
// had no comma to close it and read as a trailing comma: `[1, ,]` came out as
// `[1, ]` (length 2 -> 1), and `[a, ,] = it` pulled one value fewer from the
// iterator. Node runs the source natively for the expected output.
const source = `const r = [];
const k = (x) => Object.keys(x).join("") + "/" + x.length;
r.push(k([,]), k([1, ,]), k([, ,]), k([, 1, , 2, ,]));
let n = 0;
const it = { [Symbol.iterator]() { return { next() { n++; return { value: n, done: false }; }, return() { return {}; } }; } };
const [a, ,] = it;
let b;
[b, , ,] = it;
r.push(a, b, n);
const arr = [1, 2];
r.push(k([, ...arr]), k([...arr, ,]), k([, , ...arr, , ]));
console.log(r.join(" "));
`;

describe('arrays keep a trailing hole (#5822)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const target of ['es5', 'es2015', 'esnext']) {
    for (const extra of [[], ['--minify'], ['--bundle', '--minify']]) {
      test(`${target} ${extra.join(' ')}`, async () => {
        const created = await createFixture({ 'entry.js': source });
        cleanup = created.cleanup;
        const expected = spawnSync('node', [join(created.dir, 'entry.js')], { encoding: 'utf8' });
        expect(expected.status, expected.stderr).toBe(0);
        const out = join(created.dir, 'out.cjs');
        const result = await runZntc([
          join(created.dir, 'entry.js'),
          `--target=${target}`,
          ...extra,
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
