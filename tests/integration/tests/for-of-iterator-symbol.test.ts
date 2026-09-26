import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntcInDir } from './helpers';

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
function run(_a, _d, _step1) {
  const result = [];
  outerLoop: for (const outer of iterable('outer', [1, 2])) {
    for (const inner of iterable('inner', [outer])) {
      result.push(inner + _a + _d + _step1);
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
console.log(JSON.stringify([run(1000, 10, 100), captured.map(read => read()), events]));`;

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
});
