import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { ZNTC_BIN, createFixture, runZntcInDir } from './helpers';

const source = `const events = [];
function iterable(label, values) {
  return {
    [Symbol.iterator]() {
      let index = 0;
      return {
        next() {
          events.push(label + '.next');
          return index < values.length ? { value: values[index++], done: false } : { done: true };
        },
        return() {
          events.push(label + '.return');
          return { done: true };
        },
      };
    },
  };
}
function run(_a, _b, _c, _d, _e, _step1) {
  const result = [];
  outerLoop: for (const outer of iterable('outer', [1, 2])) {
    for (const inner of iterable('inner', [outer])) {
      result.push(inner + _a + _b + _c + _d + _e + _step1);
      break;
    }
    if (outer === 2) break outerLoop;
  }
  return result;
}
const captured = [];
for (let index = 0; index < 2; index++) {
  for (const value of iterable('captured' + index, [index])) {
    captured.push(() => value + index);
  }
}
console.log(JSON.stringify([run(1000, 100, 10, 1, 1, 100), captured.map(read => read()), events]));`;

describe('ES5 for-of iterator symbol (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const bundle of [false, true]) {
    for (const minify of [false, true]) {
      test(`${bundle ? 'bundle' : 'single'}, ${minify ? 'minify' : 'plain'}`, async () => {
        const fixture = await createFixture({
          'input.mjs': source,
          'package.json': '{"type":"module"}',
        });
        cleanup = fixture.cleanup;
        const native = spawnSync('node', [join(fixture.dir, 'input.mjs')], { encoding: 'utf8' });
        expect(native.status, native.stderr).toBe(0);
        const output = join(fixture.dir, bundle ? 'out.cjs' : 'out.mjs');
        const transformed = await runZntcInDir(fixture.dir, [
          ...(bundle ? ['--bundle', '--platform=node', '--format=cjs'] : []),
          'input.mjs',
          '--target=es5',
          ...(minify ? ['--minify'] : []),
          '-o',
          output,
        ]);
        expect(transformed.exitCode, transformed.stderr).toBe(0);
        const actual = spawnSync('node', [output], { encoding: 'utf8' });
        expect(actual.status, actual.stderr).toBe(0);
        expect(actual.stdout).toBe(native.stdout);
      });
    }
  }

  test('escaped direct eval identifiers reserve the early iterator-step name', async () => {
    const fixture = await createFixture({
      'input.mjs': `function run() {
  let observed;
  for (const value of [1]) observed = eval('typeof \\u005fstep');
  return observed;
}
console.log(run());`,
      'package.json': '{"type":"module"}',
    });
    cleanup = fixture.cleanup;
    const native = spawnSync('node', [join(fixture.dir, 'input.mjs')], { encoding: 'utf8' });
    expect(native.status, native.stderr).toBe(0);

    const transformed = await runZntcInDir(fixture.dir, [
      'input.mjs',
      '--target=es5',
      '-o',
      'out.mjs',
    ]);
    expect(transformed.exitCode, transformed.stderr).toBe(0);
    const actual = spawnSync('node', [join(fixture.dir, 'out.mjs')], { encoding: 'utf8' });
    expect(actual.status, actual.stderr).toBe(0);
    expect(actual.stdout).toBe(native.stdout);
    expect(actual.stdout.trim()).toBe('undefined');
  });

  test('standalone for-await final step names preserve exact bindings', async () => {
    const fixture = await createFixture({
      'input.mjs': `async function run(_step, _step2) {
  let total = 0;
  for await (const first of [1]) total += first;
  for await (const second of [2]) total += second;
  return total;
}
run().then((value) => console.log(value));`,
      'package.json': '{"type":"module"}',
    });
    cleanup = fixture.cleanup;
    const native = spawnSync('node', [join(fixture.dir, 'input.mjs')], { encoding: 'utf8' });
    expect(native.status, native.stderr).toBe(0);

    const transformed = await runZntcInDir(fixture.dir, [
      'input.mjs',
      '--target=es2017',
      '-o',
      'out.mjs',
    ]);
    expect(transformed.exitCode, transformed.stderr).toBe(0);
    const emitted = await Bun.file(join(fixture.dir, 'out.mjs')).text();
    expect(emitted).toContain('_step3');
    expect(emitted).toContain('_step4');
    expect(emitted).not.toContain('__zntc_step');
    const actual = spawnSync('node', [join(fixture.dir, 'out.mjs')], { encoding: 'utf8' });
    expect(actual.status, actual.stderr).toBe(0);
    expect(actual.stdout).toBe(native.stdout);
  });

  test('explicit iterator and catch bindings have exact SymbolId and ScopeId coverage', async () => {
    const fixture = await createFixture({
      'input.mjs': `function collect(xs) {
  const out = [];
  for (const value of xs) out.push(value);
  return out;
}
console.log(JSON.stringify(collect([1, 2, 3])));`,
    });
    cleanup = fixture.cleanup;
    const native = spawnSync('node', [join(fixture.dir, 'input.mjs')], { encoding: 'utf8' });
    expect(native.status, native.stderr).toBe(0);

    const transformed = spawnSync(ZNTC_BIN, ['input.mjs', '--target=es5', '-o', 'out.mjs'], {
      cwd: fixture.dir,
      env: {
        PATH: process.env.PATH ?? '/usr/bin:/bin',
        ZNTC_DEBUG_SYNTHETIC_COVERAGE: '1',
      },
      encoding: 'utf8',
    });
    expect(transformed.status, transformed.stderr).toBe(0);

    const summaries = transformed.stderr
      .split(/\r?\n/)
      .filter((line) => line.includes('synthetic-coverage') && line.includes(' bound='));
    expect(summaries).toHaveLength(1);
    const summary = summaries[0]!;
    expect(summary).toMatch(/ bound=[1-9]\d* /);
    for (const status of [
      'missing_binding',
      'invalid_id',
      'name_mismatch',
      'missing_reference',
      'identity_mismatch',
      'invalid_scope',
      'scope_unknown',
      'scope_ambiguous',
      'scope_mismatch',
      'invisible_reference',
      'duplicate_reference',
    ]) {
      expect(summary, transformed.stderr).toMatch(new RegExp(` ${status}=0 `));
    }

    // Runtime helper references now carry their own semantic provenance, so
    // iterator/catch bindings and the helper reference must all be classified.
    expect(summary).toMatch(/ unclassified=0 /);
    expect(summary).toMatch(/ symbol_identity_complete=1(?:\s|$)/);
    const unclassified = transformed.stderr
      .split(/\r?\n/)
      .filter((line) => /^\s+synthetic-coverage unclassified /.test(line));
    expect(unclassified).toHaveLength(0);

    const actual = spawnSync('node', [join(fixture.dir, 'out.mjs')], { encoding: 'utf8' });
    expect(actual.status, actual.stderr).toBe(0);
    expect(actual.stdout).toBe(native.stdout);
  });
});
