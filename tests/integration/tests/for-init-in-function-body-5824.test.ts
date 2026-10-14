import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

// #5824: a for statement's init is parsed with `in` disabled ([~In]) so `in`
// stays the for-in keyword, but function bodies, class field initializers and
// static blocks are [+In]. Entering a function did not reset the flag, so
// `for (var f = function (e) { return e in o; }; ;)` failed to parse (the
// envinfo package ships this). An arrow's concise body keeps the outer [~In].
const source = `const r = [];
const o = { a: 1 };
for (var f1 = function (e) { return e in o; }, i = 0; i < 1; i++) r.push(f1("a"));
for (var f2 = (e) => { return e in o; }; ;) { r.push(f2("b")); break; }
for (var C = class { m(e) { return e in o; } x = "a" in o; static s = "a" in o; static { r.push("a" in o); } }; ;) { r.push(new C().m("a"), new C().x, C.s); break; }
for (var g = function* () { yield "a" in o; }; ;) { r.push(g().next().value); break; }
for (var h = async () => { return "a" in o; }; ;) { h().then((v) => console.log(r.concat(v).join())); break; }
for (var k in { z: 1 }) r.push(k);
`;

describe('[+In] bodies inside a for init (#5824)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const extra of [[], ['--minify'], ['--target=es5'], ['--bundle']]) {
    test(`parses and runs ${extra.join(' ')}`, async () => {
      const created = await createFixture({ 'entry.js': source });
      cleanup = created.cleanup;
      const expected = spawnSync('node', [join(created.dir, 'entry.js')], { encoding: 'utf8' });
      expect(expected.status, expected.stderr).toBe(0);
      const out = join(created.dir, 'out.cjs');
      const result = await runZntc([join(created.dir, 'entry.js'), ...extra, '-o', out]);
      expect(result.exitCode, result.stderr).toBe(0);
      const run = spawnSync('node', [out], { encoding: 'utf8' });
      expect(run.status, run.stderr).toBe(0);
      expect(run.stdout).toBe(expected.stdout);
    });
  }

  test('an arrow concise body still rejects `in`', async () => {
    const created = await createFixture({
      'entry.js': 'const o = {};\nfor (let f = (e) => e in o; ;) break;\n',
    });
    cleanup = created.cleanup;
    const result = await runZntc([
      join(created.dir, 'entry.js'),
      '-o',
      join(created.dir, 'out.js'),
    ]);
    expect(result.exitCode).not.toBe(0);
  });
});
