import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

const cli = process.env.ZNTC_STATEMENT_IDENTITY_CLI ?? ZNTC_BIN;
const cases = [
  {
    name: 'implicit base',
    source: 'class Box{#value=1;read(){return this.#value;}}console.log(new Box().read());',
  },
  {
    name: 'implicit derived',
    source:
      'class Base{};class Box extends Base{#value=1;read(){return this.#value;}}console.log(new Box().read());',
  },
  {
    name: 'existing constructor',
    source:
      'class Box{constructor(value=1){this.value=value;}#value=2;read(){return this.#value;}}console.log(new Box().read());',
  },
  {
    name: 'class expression',
    source: 'const Box=class{#value=3;read(){return this.#value;}};console.log(new Box().read());',
  },
  {
    name: 'returned class',
    source:
      'function make(){return class{#value=4;read(){return this.#value;}};}console.log(new(make())().read());',
  },
  {
    name: 'getter',
    source: 'class Box{#value=5;get value(){return this.#value;}}console.log(new Box().value);',
  },
  {
    name: 'private write',
    source:
      'class Box{#value=0;read(){this.#value=6;return this.#value;}}console.log(new Box().read());',
  },
  {
    name: 'private arrow',
    source: 'class Box{#value=7;read=()=>this.#value;}console.log(new Box().read());',
  },
  {
    name: 'nested same spelling',
    source:
      'class Box{#value=8;read(){class Inner{#value=9;read(){return this.#value;}}return[this.#value,new Inner().read()];}}console.log(JSON.stringify(new Box().read()));',
  },
  {
    name: 'unused storage control',
    source:
      'class Unused{#value=10;read(){return this.#value;}}class Box{#value=11;read(){return this.#value;}}console.log(new Box().read());',
  },
];

describe('statement dependencies follow binding roles (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });
  for (const fixture of cases) {
    for (const target of ['es2022', 'es2021', 'es2020', 'es2017', 'es2015', 'es5']) {
      for (const bundle of [false, true]) {
        for (const minify of [[], ['--minify-identifiers'], ['--minify']]) {
          test(`${fixture.name}: ${target}, ${bundle ? 'bundle' : 'standalone'}, ${minify.join(' ') || 'plain'}`, async () => {
            const created = await createFixture({ 'input.cjs': fixture.source });
            cleanup = created.cleanup;
            const input = join(created.dir, 'input.cjs');
            const output = join(created.dir, 'output.cjs');
            const native = spawnSync('node', [input], { encoding: 'utf8' });
            expect(native.status, native.stderr).toBe(0);
            const built = spawnSync(
              cli,
              [
                input,
                `--target=${target}`,
                '--format=cjs',
                ...(bundle ? ['--bundle', '--platform=node'] : []),
                ...minify,
                '-o',
                output,
              ],
              { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
            );
            expect(built.status, built.stderr).toBe(0);
            expect(built.stderr).not.toContain('clean=0');
            const actual = spawnSync('node', [output], { encoding: 'utf8' });
            expect(actual.status, actual.stderr).toBe(native.status);
            expect(actual.stdout).toBe(native.stdout);
          });
        }
      }
    }
  }
});
