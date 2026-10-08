import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntcInDir } from './helpers';

const source = `
class Counter {
  static #method(value = Counter) {
    function nested() { return Counter; }
    return [Counter, value, nested()];
  }
  static #evalClass() { return eval('Counter'); }
  static #assignClass() { Counter = null; }
  static #shadow(Counter) { function nested() { return Counter; } return [Counter, nested()]; }
  static get #entry() { return Counter; }
  static set #entry(value) { globalThis.observedClass = Counter; }
  static run() { return this.#method(); }
  static evalClass() { return this.#evalClass(); }
  static assignClass() {
    try { this.#assignClass(); } catch (error) { return error instanceof TypeError; }
    return false;
  }
  static shadow() { return this.#shadow('parameter'); }
  static read() { return this.#entry; }
  static write() { this.#entry = 1; return globalThis.observedClass; }
}
const Saved = Counter;
Counter = null;
console.log(JSON.stringify([
  Saved.run().every(value => value === Saved),
  Saved.evalClass() === Saved,
  Saved.assignClass(),
  JSON.stringify(Saved.shadow()) === '["parameter","parameter"]',
  Saved.read() === Saved,
  Saved.write() === Saved,
]));
`;

const classExpressionSource = `
let outer = class LocalCounter {
  #instance() { return LocalCounter; }
  static #method() { return LocalCounter; }
  static read() { return this.#method(); }
  readInstance() { return this.#instance(); }
};
const Saved = outer;
outer = null;
console.log(Saved.read() === Saved, new Saved().readInstance() === Saved);
`;

const instanceSource = `
class Counter {
  #method() { return Counter; }
  read() { return this.#method(); }
}
const Saved = Counter;
Counter = null;
console.log(new Saved().read() === Saved);
`;

describe('extracted private methods retain class self identity (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const target of ['es2015', 'es5']) {
    test(`outer class reassignment does not change extracted method identity (${target})`, async () => {
      const fixture = await createFixture({
        'input.mjs': source,
        'package.json': '{"type":"module"}',
      });
      cleanup = fixture.cleanup;

      const native = spawnSync('node', [join(fixture.dir, 'input.mjs')], { encoding: 'utf8' });
      expect(native.status, native.stderr).toBe(0);
      const output = join(fixture.dir, 'out.mjs');
      const result = await runZntcInDir(fixture.dir, [
        'input.mjs',
        `--target=${target}`,
        '-o',
        output,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);

      const runtime = spawnSync('node', [output], { encoding: 'utf8' });
      expect(runtime.status, runtime.stderr).toBe(0);
      expect(runtime.stdout).toBe(native.stdout);
    });

    test(`named class expressions retain their private method identity (${target})`, async () => {
      const fixture = await createFixture({
        'input.mjs': classExpressionSource,
        'package.json': '{"type":"module"}',
      });
      cleanup = fixture.cleanup;

      const native = spawnSync('node', [join(fixture.dir, 'input.mjs')], { encoding: 'utf8' });
      expect(native.status, native.stderr).toBe(0);
      const output = join(fixture.dir, 'out.mjs');
      const result = await runZntcInDir(fixture.dir, [
        'input.mjs',
        `--target=${target}`,
        '-o',
        output,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);

      const runtime = spawnSync('node', [output], { encoding: 'utf8' });
      expect(runtime.status, runtime.stderr).toBe(0);
      expect(runtime.stdout).toBe(native.stdout);
    });

    test(`instance private methods retain class self identity (${target})`, async () => {
      const fixture = await createFixture({
        'input.mjs': instanceSource,
        'package.json': '{"type":"module"}',
      });
      cleanup = fixture.cleanup;

      const native = spawnSync('node', [join(fixture.dir, 'input.mjs')], { encoding: 'utf8' });
      expect(native.status, native.stderr).toBe(0);
      const output = join(fixture.dir, 'out.mjs');
      const result = await runZntcInDir(fixture.dir, [
        'input.mjs',
        `--target=${target}`,
        '-o',
        output,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);

      const runtime = spawnSync('node', [output], { encoding: 'utf8' });
      expect(runtime.status, runtime.stderr).toBe(0);
      expect(runtime.stdout).toBe(native.stdout);
    });
  }

  for (const target of ['es2015', 'es5']) {
    for (const [label, input] of [
      ['static', source],
      ['instance', instanceSource],
    ] as const) {
      test(`bundled and minified ${label} helper preserves class self identity (${target})`, async () => {
        const fixture = await createFixture({
          'input.mjs': input,
          'package.json': '{"type":"module"}',
        });
        cleanup = fixture.cleanup;

        const native = spawnSync('node', [join(fixture.dir, 'input.mjs')], { encoding: 'utf8' });
        expect(native.status, native.stderr).toBe(0);
        const output = join(fixture.dir, 'out.mjs');
        const result = await runZntcInDir(fixture.dir, [
          '--bundle',
          '--platform=node',
          '--format=esm',
          'input.mjs',
          `--target=${target}`,
          '--minify-identifiers',
          '--minify-syntax',
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
});
