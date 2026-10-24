import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

const cases = [
  {
    name: 'detached arrow',
    source:
      'class Box { static value = 7; static read = () => this.value; } const read = Box.read; console.log(read());',
  },
  {
    name: 'function local declaration',
    source:
      'function create() { class Box { static value = 3; static read = () => this.value; } return Box; } console.log(create().read());',
  },
  {
    name: 'same spelling in separate owners',
    source:
      'function create(n) { class Box { static value = n; static read = () => this.value; } return Box; } class Box { static value = 9; static read = () => this.value; } console.log(create(2).read(), Box.read());',
  },
  {
    name: 'escaped declaration',
    source: String.raw`class \u0042ox { static value = 4; static read = () => this.value; } console.log(Box.read());`,
  },
  {
    name: 'static super receiver',
    source:
      'class Base { static value = 5; } class Box extends Base { static extra = 2; static read = () => super.value + this.extra; } console.log(Box.read());',
  },
  {
    name: 'static block arrow',
    source:
      'class Box { static { this.value = 6; this.read = () => this.value; } } console.log(Box.read());',
  },
  {
    name: 'private static state',
    source:
      'class Box { static value = 7; static #read = () => this.value; static read() { return Box.#read(); } } console.log(Box.read());',
  },
  {
    name: 'nested arrows preserve static this',
    source:
      'class Box { static get value() { return 8; } static read = () => () => this.value; } console.log(Box.read()());',
  },
  {
    name: 'named class expression wrapper',
    source:
      'const Outer = class Inner { static value = 9; static read = () => this.value + Inner.value; }; console.log(Outer.read());',
  },
  {
    name: 'anonymous class wrapper',
    source:
      'function create() { return class { static value = 10; static read = () => this.value; }; } console.log(create().read());',
  },
];

describe('moved static class references keep producer identity (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const fixture of cases) {
    for (const target of ['es2015', 'es2017', 'es5']) {
      for (const bundle of [false, true]) {
        for (const minify of [[], ['--minify-identifiers'], ['--minify']]) {
          test(`${fixture.name}: ${target}, ${bundle ? 'bundle' : 'standalone'}, ${minify.join(' ') || 'plain'}`, async () => {
            const created = await createFixture({ 'input.mjs': fixture.source });
            cleanup = created.cleanup;
            const input = join(created.dir, 'input.mjs');
            const native = spawnSync('node', [input], { encoding: 'utf8' });
            expect(native.status, native.stderr).toBe(0);
            const output = join(created.dir, 'output.mjs');
            const built = await runZntc(
              [
                input,
                `--target=${target}`,
                ...(bundle ? ['--bundle', '--platform=node'] : []),
                ...minify,
                '-o',
                output,
              ],
              { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
            );
            expect(built.exitCode, built.stderr).toBe(0);
            expect(built.stderr).not.toContain('clean=0');
            const executed = spawnSync('node', [output], { encoding: 'utf8' });
            expect(executed.status, executed.stderr).toBe(0);
            expect(executed.stdout).toBe(native.stdout);
          });
        }
      }
    }
  }
});
