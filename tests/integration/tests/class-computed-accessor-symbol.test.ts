import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

describe('retained computed class accessor symbols (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  test('static string accessor keys retain exact setter identity and runtime behavior', async () => {
    const fixture = await createFixture({
      'input.js': `var _key = 'source-key';
class Box {
  get ['value']() { return this._stored + ':' + _key; }
  set ["value"](value = 1) { this._stored = value; }
}
const box = new Box();
box.value = undefined;
console.log(box.value, _key);
box.value = null;
console.log(box.value, _key);`,
    });
    cleanup = fixture.cleanup;

    const native = spawnSync('node', ['input.js'], { cwd: fixture.dir, encoding: 'utf8' });
    expect(native.status, native.stderr).toBe(0);

    const output = join(fixture.dir, 'out.cjs');
    const transformed = spawnSync(
      ZNTC_BIN,
      ['--bundle', 'input.js', '--target=es5', '--platform=node', '--format=cjs', '-o', output],
      {
        cwd: fixture.dir,
        env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
        encoding: 'utf8',
      },
    );
    expect(transformed.status, transformed.stderr).toBe(0);

    const mode = transformed.stderr
      .split(/\r?\n/)
      .find(
        (line) =>
          line.startsWith('zntc: symbol-identity-prepass-mode ') && line.includes('input.js'),
      );
    expect(mode, transformed.stderr).toContain('semantic_graph=retained');
    const report = transformed.stderr
      .split(/\r?\n/)
      .find(
        (line) => line.startsWith('zntc: symbol-identity-prepass ') && line.includes('input.js'),
      );
    expect(report, transformed.stderr).toMatch(/clean=1(?:\s|$)/);

    const actual = spawnSync('node', [output], { cwd: fixture.dir, encoding: 'utf8' });
    expect(actual.status, actual.stderr).toBe(0);
    expect(actual.stdout).toBe(native.stdout);
  });

  test('dynamic class accessor keys preserve evaluation order', async () => {
    const fixture = await createFixture({
      'input.js': `let calls = 0;
function nextKey() { calls++; return 'value'; }
class Box {
  get [nextKey()]() { return this._stored; }
  set [nextKey()](value = 1) { this._stored = value; }
}
const box = new Box();
box.value = undefined;
console.log(calls, box.value);`,
    });
    cleanup = fixture.cleanup;

    const native = spawnSync('node', ['input.js'], { cwd: fixture.dir, encoding: 'utf8' });
    expect(native.status, native.stderr).toBe(0);

    const output = join(fixture.dir, 'out.cjs');
    const transformed = spawnSync(
      ZNTC_BIN,
      ['--bundle', 'input.js', '--target=es5', '--platform=node', '--format=cjs', '-o', output],
      {
        cwd: fixture.dir,
        env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
        encoding: 'utf8',
      },
    );
    expect(transformed.status, transformed.stderr).toBe(0);

    const actual = spawnSync('node', [output], { cwd: fixture.dir, encoding: 'utf8' });
    expect(actual.status, actual.stderr).toBe(0);
    expect(actual.stdout).toBe(native.stdout);
  });
});
