import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { ZNTC_BIN, createFixture, runZntcInDir } from './helpers';

const source = `
const _a = 99;
function nested() {
  const _b = 100;
  {
    const { x, nested: { y = 3 } } = { x: 1, nested: {} };
    const {} = { ignored: true };
    return x + y + _a + _b;
  }
}
const values = [];
for (const { x } of [{ x: 1 }, { x: 2 }]) values.push(x);
let keyCalls = 0;
function key() { keyCalls++; return 'x'; }
const { [key()]: picked, ...rest } = { x: 4, y: 5 };
const [] = [];
console.log(JSON.stringify([nested(), values, picked, rest.y, keyCalls]));
`;

const lexicalSource = `
function f() {
  let _a = 9;
  {
    const { x, ...tail } = { x: 1, y: 2 };
    let { z, ...more } = { z: 3, w: 4 };
    return x + z + tail.y + more.w + _a;
  }
}
console.log(f());
`;

const assignmentCases = [
  {
    target: 'es5',
    source: `
const _a = 99;
let calls = 0;
function source() { calls++; return { x: 3, nested: { value: 4 } }; }
function run() {
  let x = 0;
  {
    let y = 0;
    const assigned = ({ x, nested: { value: y } } = source());
    [x, y] = [x + 1, y + 1];
    return [x, y, assigned.x, calls, _a];
  }
}
console.log(JSON.stringify(run()));
`,
  },
  {
    target: 'es2015',
    source: `
const _a = 99;
let calls = 0;
function source() { calls++; return { x: 3, y: 4 }; }
function run() {
  let x = 0;
  {
    let rest;
    const assigned = ({ x, ...rest } = source());
    return [x, rest.y, assigned.y, calls, _a];
  }
}
console.log(JSON.stringify(run()));
`,
  },
] as const;

describe('ES5 destructuring generated temp provenance (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const { target, source: assignmentSource } of assignmentCases) {
    for (const bundle of [false, true]) {
      for (const minify of [false, true]) {
        test(`${target} assignment temps, ${bundle ? 'bundle' : 'single'}, ${minify ? 'minify' : 'plain'}`, async () => {
          const fixture = await createFixture({
            'input.mjs': assignmentSource,
            'package.json': '{"type":"module"}',
          });
          cleanup = fixture.cleanup;
          const native = spawnSync('node', [join(fixture.dir, 'input.mjs')], { encoding: 'utf8' });
          expect(native.status, native.stderr).toBe(0);
          const out = join(fixture.dir, bundle ? 'out.cjs' : 'out.mjs');
          const result = await runZntcInDir(fixture.dir, [
            ...(bundle ? ['--bundle', '--platform=node', '--format=cjs'] : []),
            'input.mjs',
            `--target=${target}`,
            ...(minify ? ['--minify'] : []),
            '-o',
            out,
          ]);
          expect(result.exitCode, result.stderr).toBe(0);
          const actual = spawnSync('node', [out], { encoding: 'utf8' });
          expect(actual.status, actual.stderr).toBe(0);
          expect(actual.stdout).toBe(native.stdout);
        });
      }
    }
  }

  for (const { target, source: assignmentSource } of assignmentCases) {
    test(`${target} assignment temps have no missing synthetic binding`, async () => {
      const fixture = await createFixture({ 'input.mjs': assignmentSource });
      cleanup = fixture.cleanup;
      const result = spawnSync(ZNTC_BIN, ['input.mjs', `--target=${target}`, '-o', 'out.mjs'], {
        cwd: fixture.dir,
        env: {
          PATH: process.env.PATH ?? '/usr/bin:/bin',
          ZNTC_DEBUG_SYNTHETIC_COVERAGE: '1',
          ZNTC_DEBUG_SYMBOL_COVERAGE: '1',
        },
        encoding: 'utf8',
      });
      expect(result.status, result.stderr).toBe(0);
      expect(result.stderr).toMatch(/synthetic-coverage .* missing_binding=0 /);
      expect(result.stderr).toMatch(/symbol-coverage .* missing=0 wrong=0/);
    });
  }

  for (const bundle of [false, true]) {
    for (const minify of [false, true]) {
      test(`${bundle ? 'bundle' : 'single'}, ${minify ? 'minify' : 'plain'}`, async () => {
        const fixture = await createFixture({
          'input.mjs': source,
          'package.json': '{"type":"module"}',
        });
        cleanup = fixture.cleanup;
        const native = spawnSync('node', [join(fixture.dir, 'input.mjs')], {
          encoding: 'utf8',
        });
        expect(native.status, native.stderr).toBe(0);
        const out = join(fixture.dir, bundle ? 'out.cjs' : 'out.mjs');
        const result = await runZntcInDir(fixture.dir, [
          ...(bundle ? ['--bundle', '--platform=node', '--format=cjs'] : []),
          'input.mjs',
          '--target=es5',
          ...(minify ? ['--minify'] : []),
          '-o',
          out,
        ]);
        expect(result.exitCode, result.stderr).toBe(0);
        const actual = spawnSync('node', [out], { encoding: 'utf8' });
        expect(actual.status, actual.stderr).toBe(0);
        expect(actual.stdout).toBe(native.stdout);
      });
    }
  }

  test('used and empty declaration temps have generated SymbolIds', async () => {
    const fixture = await createFixture({
      'input.mjs': 'const _a = 99; const { x } = { x: 1 }; const {} = {}; console.log(_a + x);',
    });
    cleanup = fixture.cleanup;
    const result = spawnSync(ZNTC_BIN, ['input.mjs', '--target=es5', '-o', 'out.mjs'], {
      cwd: fixture.dir,
      env: {
        PATH: process.env.PATH ?? '/usr/bin:/bin',
        ZNTC_DEBUG_SYNTHETIC_COVERAGE: '1',
      },
      encoding: 'utf8',
    });
    expect(result.status, result.stderr).toBe(0);
    expect(result.stderr).toMatch(/synthetic-coverage .* bound=\d+ missing_binding=0 /);
  });

  for (const target of ['es2015', 'es2017']) {
    for (const bundle of [false, true]) {
      for (const minify of [false, true]) {
        test(`${target} lexical object rest, ${bundle ? 'bundle' : 'single'}, ${minify ? 'minify' : 'plain'}`, async () => {
          const fixture = await createFixture({
            'input.mjs': lexicalSource,
            'package.json': '{"type":"module"}',
          });
          cleanup = fixture.cleanup;
          const native = spawnSync('node', [join(fixture.dir, 'input.mjs')], {
            encoding: 'utf8',
          });
          expect(native.status, native.stderr).toBe(0);
          const out = join(fixture.dir, bundle ? 'out.cjs' : 'out.mjs');
          const result = await runZntcInDir(fixture.dir, [
            ...(bundle ? ['--bundle', '--platform=node', '--format=cjs'] : []),
            'input.mjs',
            `--target=${target}`,
            ...(minify ? ['--minify'] : []),
            '-o',
            out,
          ]);
          expect(result.exitCode, result.stderr).toBe(0);
          const actual = spawnSync('node', [out], { encoding: 'utf8' });
          expect(actual.status, actual.stderr).toBe(0);
          expect(actual.stdout).toBe(native.stdout);
        });
      }
    }
  }
});
