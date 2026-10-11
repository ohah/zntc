import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

describe('ES2021 lowering temp symbols (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  test('synchronous nullish-assignment captures use exact SymbolIds', async () => {
    const fixture = await createFixture({
      'input.js': `var _a = 'outer-a';
var _b = 'outer-b';
var calls = 0;
var box = { value: null };
function getBox() { calls++; return box; }
function assignInside() { return getBox().value ??= 7; }
var functionValue = assignInside();
box.value = null;
var topLevelValue = getBox().value ??= 8;
console.log(functionValue, topLevelValue, calls, _a, _b);`,
    });
    cleanup = fixture.cleanup;
    const native = spawnSync('node', [join(fixture.dir, 'input.js')], { encoding: 'utf8' });
    expect(native.status, native.stderr).toBe(0);

    for (const minifyIdentifiers of [false, true]) {
      const output = join(fixture.dir, `out-${minifyIdentifiers ? 'minified' : 'plain'}.js`);
      const args = ['input.js', '--target=es5'];
      if (minifyIdentifiers) args.push('--minify-identifiers');
      args.push('-o', output);
      const transformed = spawnSync(ZNTC_BIN, args, {
        cwd: fixture.dir,
        env: {
          ...process.env,
          ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
          ZNTC_DEBUG_SYNTHETIC_COVERAGE: '1',
        },
        encoding: 'utf8',
      });
      expect(transformed.status, transformed.stderr).toBe(0);

      const lines = transformed.stderr.split(/\r?\n/);
      const report = lines.find(
        (line) => line.startsWith('zntc: symbol-identity ') && line.includes('input.js'),
      );
      expect(report, transformed.stderr).toMatch(/unclassified_reference=0(?:\s|$)/);
      expect(report, transformed.stderr).toMatch(/clean=1(?:\s|$)/);
      const strict = lines.find(
        (line) => line.startsWith('zntc: synthetic-coverage ') && line.includes('input.js'),
      );
      expect(strict, transformed.stderr).toMatch(/orphan_symbols=0(?:\s|$)/);
      expect(strict, transformed.stderr).toMatch(/symbol_identity_complete=1(?:\s|$)/);

      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe(native.stdout);
      expect(actual.stdout).toBe('7 8 2 outer-a outer-b\n');
    }
  });

  test('async and generator captures stay deferred until callback scopes exist', async () => {
    const fixture = await createFixture({
      'input.js': `var calls = 0;
var box = { value: null };
function getBox() { calls++; return box; }
function* generate() { yield getBox().value ??= 6; }
async function run() { return getBox().value ??= 7; }
var generatorValue = generate().next().value;
box.value = null;
run().then((asyncValue) => console.log(generatorValue, asyncValue, calls));`,
    });
    cleanup = fixture.cleanup;
    const native = spawnSync('node', [join(fixture.dir, 'input.js')], { encoding: 'utf8' });
    expect(native.status, native.stderr).toBe(0);
    const output = join(fixture.dir, 'out.js');
    const transformed = spawnSync(ZNTC_BIN, ['input.js', '--target=es5', '-o', output], {
      cwd: fixture.dir,
      env: {
        ...process.env,
        ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
        ZNTC_DEBUG_SYNTHETIC_COVERAGE: '1',
      },
      encoding: 'utf8',
    });
    expect(transformed.status, transformed.stderr).toBe(0);
    const lines = transformed.stderr.split(/\r?\n/);
    const report = lines.find(
      (line) => line.startsWith('zntc: symbol-identity ') && line.includes('input.js'),
    );
    expect(report, transformed.stderr).toMatch(/unclassified_reference=0(?:\s|$)/);
    expect(report, transformed.stderr).toMatch(/clean=1(?:\s|$)/);
    const strict = lines.find(
      (line) => line.startsWith('zntc: synthetic-coverage ') && line.includes('input.js'),
    );
    expect(strict, transformed.stderr).toMatch(/orphan_symbols=0(?:\s|$)/);
    expect(strict, transformed.stderr).toMatch(/symbol_identity_complete=1(?:\s|$)/);

    const actual = spawnSync('node', [output], { encoding: 'utf8' });
    expect(actual.status, actual.stderr).toBe(0);
    expect(actual.stdout).toBe(native.stdout);
    expect(actual.stdout).toBe('6 7 2\n');
  });
});
