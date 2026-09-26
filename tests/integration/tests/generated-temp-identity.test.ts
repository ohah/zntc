import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntcInDir } from './helpers';

describe('generated temp allocation identity (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const bundled of [false, true]) {
    test(`${bundled ? 'bundle' : 'single-file'} keeps nested and top-level temps distinct`, async () => {
      const fixture = await createFixture({
        'input.mjs': `
const _a = 40;
function outer(value) {
  const _b = 2;
  function inner(input) { return (input ?? _b) + _a; }
  return inner(value) + (value ?? 3);
}
function sibling(value) { return (Object.assign({ x: value }, {}).x ?? 6) + _a; }
const receiver = { x: 3, method: function () { return this.x + _a; } };
function getReceiver(enabled) { return enabled ? receiver : null; }
function call(value) { return value?.method?.(); }
const holder = { Box: function (x) { this.x = x; } };
function makeBox(value) { return new holder.Box(...[value]); }
let accesses = 0;
const assignBox = { x: null };
function objForAssign() { accesses++; return assignBox; }
function keyForAssign() { accesses++; return 'x'; }
function assignInside() { return objForAssign()[keyForAssign()] ??= 11; }
const firstAssign = assignInside();
assignBox.x = null;
const secondAssign = objForAssign()[keyForAssign()] ??= 12;
let updateCalls = 0;
const updateBox = { x: 0 };
function updateObj() { updateCalls++; return updateBox; }
function updateKey() { updateCalls++; return 'x'; }
updateObj()[updateKey()] ||= 3;
updateObj()[updateKey()] **= 2;
console.log(outer(null), outer(1), sibling(null), sibling(2), Object.assign({ x: null }, {}).x ?? 5, getReceiver(true)?.method?.(), call(receiver), String(call(null)), new holder.Box(...[8]).x, makeBox(9).x, firstAssign, secondAssign, accesses, updateBox.x, updateCalls, _a);
`,
      });
      cleanup = fixture.cleanup;
      const out = join(fixture.dir, 'out.cjs');
      const result = await runZntcInDir(fixture.dir, [
        ...(bundled ? ['--bundle'] : []),
        'input.mjs',
        '--target=es5',
        '--minify-identifiers',
        '--minify-syntax',
        ...(bundled ? ['--platform=node', '--format=cjs'] : []),
        '-o',
        out,
      ]);
      expect(result.exitCode).toBe(0);
      const runtime = spawnSync('node', [out], { encoding: 'utf8' });
      expect(runtime.status).toBe(0);
      expect(runtime.stdout.trim()).toBe('45 42 46 42 5 43 43 undefined 8 9 11 12 4 9 4 40');
    });
  }
});
