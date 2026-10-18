import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

describe('ES2020 lowering temp symbols (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  test('synchronous nullish and optional-chain temps attach refs to their exact SymbolId', async () => {
    const fixture = await createFixture({
      'input.js': `var _a = 'outer-a';
var _b = 'outer-b';
var calls = 0;
function getBox(value) { calls++; return value; }
function readNullish() { return getBox(null) ?? 7; }
function readOptional() { return getBox({ value: 42 })?.value; }
console.log(readNullish(), readOptional(), calls, _a, _b);`,
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
      expect(report, transformed.stderr).toMatch(/generated_bindings=[2-9]\d*(?:\s|$)/);
      expect(report, transformed.stderr).toMatch(/generated_references=[4-9]\d*(?:\s|$)/);
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
      expect(actual.stdout).toBe('7 42 2 outer-a outer-b\n');
    }
  });

  test('async and generator callback temps retain pending identity until owner scopes exist', async () => {
    const fixture = await createFixture({
      'input.js': `var calls = 0;
function getValue(value) { calls++; return value; }
function* makeGenerator() { yield getValue(null) ?? 8; }
async function makeAsync() { return getValue(null) ?? 9; }
var generatorValue = makeGenerator().next().value;
makeAsync().then((asyncValue) => console.log(generatorValue, asyncValue, calls));`,
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'out.js');
    const native = spawnSync('node', [join(fixture.dir, 'input.js')], { encoding: 'utf8' });
    expect(native.status, native.stderr).toBe(0);
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
    expect(actual.stdout).toBe('8 9 2\n');
  });

  test('10 async and generator producer shapes retain exact callback temp identities', async () => {
    const cases = [
      {
        name: 'generator yield',
        source: `function getValue(value) { return value; }
function* values() { yield getValue(null) ?? 8; }
console.log(values().next().value);`,
      },
      {
        name: 'async return',
        source: `function getValue(value) { return value; }
async function value() { return getValue(null) ?? 9; }
value().then((result) => console.log(result));`,
      },
      {
        name: 'multiple generator steps',
        source: `function getValue(value) { return value; }
function* values() { yield getValue(null) ?? 4; yield getValue(5) ?? 6; }
const iterator = values();
console.log(iterator.next().value, iterator.next().value);`,
      },
      {
        name: 'async temp before and after await',
        source: `function getValue(value) { return value; }
async function value() {
  const first = getValue(null) ?? 6;
  const second = getValue(2) ?? (await Promise.resolve(8));
  return first + second;
}
value().then((result) => console.log(result));`,
      },
      {
        name: 'async generator yields',
        source: `function getValue(value) { return value; }
async function* values() { yield getValue(null) ?? 7; yield getValue(3) ?? 9; }
(async () => { const iterator = values(); console.log((await iterator.next()).value, (await iterator.next()).value); })();`,
      },
      {
        name: 'nested generator in async function',
        source: `function getValue(value) { return value; }
async function value() {
  function* nested() { yield getValue(null) ?? 2; }
  return nested().next().value;
}
value().then((result) => console.log(result));`,
      },
      {
        name: 'object generator method',
        source: `function getValue(value) { return value; }
const source = { *values() { yield getValue(null) ?? 5; } };
console.log(source.values().next().value);`,
      },
      {
        name: 'object async method',
        source: `function getValue(value) { return value; }
const source = { async value() { return getValue(null) ?? 5; } };
source.value().then((result) => console.log(result));`,
      },
      {
        name: 'user _a shadow in generator',
        source: `function getValue(value) { return value; }
var _a = 'outer';
function* values() { var _a = 'inner'; yield getValue(null) ?? _a; }
console.log(values().next().value, _a);`,
      },
      {
        name: 'generator suspended inside nullish fallback',
        source: `function getValue(value) { return value; }
function* values() { yield getValue(null) ?? (yield 7); }
const iterator = values();
console.log(iterator.next().value, iterator.next(11).value);`,
      },
    ];

    for (const fixtureCase of cases) {
      const fixture = await createFixture({ 'input.js': fixtureCase.source });
      try {
        const input = join(fixture.dir, 'input.js');
        const native = spawnSync('node', [input], { encoding: 'utf8' });
        expect(native.status, `${fixtureCase.name}: ${native.stderr}`).toBe(0);

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
        expect(transformed.status, `${fixtureCase.name}: ${transformed.stderr}`).toBe(0);

        const strict = transformed.stderr
          .split(/\r?\n/)
          .find((line) => line.startsWith('zntc: synthetic-coverage '));
        expect(strict, fixtureCase.name).toMatch(/orphan_symbols=0(?:\s|$)/);
        expect(strict, fixtureCase.name).toMatch(/symbol_identity_complete=1(?:\s|$)/);

        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, `${fixtureCase.name}: ${actual.stderr}`).toBe(0);
        expect(actual.stdout, fixtureCase.name).toBe(native.stdout);
      } finally {
        await fixture.cleanup();
      }
    }
  }, 60_000);

  test('top-level-await wrapper preserves nullish temp identity and execution', async () => {
    const fixture = await createFixture({
      'input.js': `var calls = 0;
function getValue(value) { calls++; return value; }
var result = getValue(null) ?? await Promise.resolve(9);
console.log(result, calls);`,
      'package.json': '{"type":"module"}',
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'out.js');
    const native = spawnSync('node', [join(fixture.dir, 'input.js')], { encoding: 'utf8' });
    expect(native.status, native.stderr).toBe(0);
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
    expect(report, transformed.stderr).toMatch(/clean=1(?:\s|$)/);
    const strict = lines.find(
      (line) => line.startsWith('zntc: synthetic-coverage ') && line.includes('input.js'),
    );
    expect(strict, transformed.stderr).toMatch(/orphan_symbols=0(?:\s|$)/);
    expect(strict, transformed.stderr).toMatch(/symbol_identity_complete=1(?:\s|$)/);

    const actual = spawnSync('node', [output], { encoding: 'utf8' });
    expect(actual.status, actual.stderr).toBe(0);
    expect(actual.stdout).toBe(native.stdout);
    expect(actual.stdout).toBe('9 1\n');
  });
});
