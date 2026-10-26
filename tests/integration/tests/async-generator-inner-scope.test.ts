import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createFixture, runZntcInDir, ZNTC_BIN } from './helpers';

const capturedForAwait = readFileSync(
  join(import.meta.dir, '../fixtures/downlevel-oracle/forof-in-forawait-yield-capture.mjs'),
  'utf8',
);
const generatorUsingForAwait = readFileSync(
  join(import.meta.dir, '../fixtures/downlevel-oracle/4730-using-30.mjs'),
  'utf8',
);

const defaultSemantics = `
  (async () => {
    const events = [];
    const host = {
      base: 3,
      async *run(input = (events.push('default:' + this.base + ':' + arguments.length), 2)) {
        const nested = () => input + this.base + arguments.length;
        events.push('body');
        yield nested();
      },
      async *fail(input = (() => { events.push('throw-default'); throw Error('boom'); })()) {
        yield input;
      }
    };
    const iterator = host.run();
    events.push('after-call');
    try { host.fail(); events.push('after-fail-call'); }
    catch (error) { events.push('caught-call:' + error.message); }
    console.log(JSON.stringify([events, (await iterator.next()).value]));
  })();
`;

describe('async generator inner function scope (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const [name, source] of [
    ['captured for-of inside for-await', capturedForAwait],
    ['default evaluation, this, arguments, closure and throw timing', defaultSemantics],
  ] as const) {
    for (const bundle of [false, true]) {
      for (const minify of [false, true]) {
        test(`${name}, ${bundle ? 'bundle' : 'single'}, ${minify ? 'minify' : 'plain'}`, async () => {
          const fixture = await createFixture({
            'input.mjs': source,
            'package.json': '{"type":"module"}',
          });
          cleanup = fixture.cleanup;
          const input = join(fixture.dir, 'input.mjs');
          const native = spawnSync('node', [input], { encoding: 'utf8' });
          expect(native.status, native.stderr).toBe(0);
          const output = join(fixture.dir, bundle ? 'out.cjs' : 'out.mjs');
          const result = await runZntcInDir(fixture.dir, [
            ...(bundle ? ['--bundle', '--platform=node', '--format=cjs'] : []),
            'input.mjs',
            '--target=es5',
            ...(minify ? ['--minify'] : []),
            '-o',
            output,
          ]);
          expect(result.exitCode, result.stderr).toBe(0);
          const runtime = spawnSync('node', [output], { encoding: 'utf8' });
          expect(runtime.status, runtime.stderr).toBe(0);
          expect(runtime.stdout).toBe(native.stdout);
        });
      }
    }
  }

  test('minified await helper alias is not shadowed by async-generator template locals (#4819)', async () => {
    const source = `
      const __await = 1;
      async function* run() { yield await Promise.resolve(__await + 1); }
      run().next().then(result => console.log(JSON.stringify(result)));
    `;
    const fixture = await createFixture({
      'input.mjs': source,
      'package.json': '{"type":"module"}',
    });
    cleanup = fixture.cleanup;
    const input = join(fixture.dir, 'input.mjs');
    const native = spawnSync('node', [input], { encoding: 'utf8' });
    expect(native.status, native.stderr).toBe(0);

    const output = join(fixture.dir, 'out.mjs');
    const result = await runZntcInDir(fixture.dir, [
      'input.mjs',
      '--target=es2015',
      '--minify-identifiers',
      '-o',
      output,
    ]);
    expect(result.exitCode, result.stderr).toBe(0);
    const runtime = spawnSync('node', [output], { encoding: 'utf8' });
    expect(runtime.status, runtime.stderr).toBe(0);
    expect(runtime.stdout).toBe(native.stdout);
  });

  for (const [targetName, target] of [
    ['ES5', '--target=es5'],
    ['Hermes', '--platform=react-native'],
  ] as const) {
    for (const minify of [false, true]) {
      test(`bundle reindexes program coordinates without widening generator storage authority (#6355, ${targetName}, ${minify ? 'minified' : 'plain'})`, async () => {
        const fixture = await createFixture({
          'input.mjs': generatorUsingForAwait,
          'package.json': '{"type":"module"}',
        });
        try {
          const output = join(fixture.dir, 'out.mjs');
          const result = spawnSync(
            ZNTC_BIN,
            ['--bundle', 'input.mjs', target, ...(minify ? ['--minify'] : []), '-o', output],
            { cwd: fixture.dir, encoding: 'utf8', stdio: 'pipe' },
          );
          expect(result.status, result.stderr).toBe(0);
        } finally {
          await fixture.cleanup();
        }
      });
    }
  }
});
