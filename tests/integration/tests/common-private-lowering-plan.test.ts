import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

const cli = process.env.ZNTC_COMMON_PRIVATE_PLAN_CLI ?? ZNTC_BIN;
// The surrounding .cjs remains sloppy; class-derived functions remain strict.
// Compare each generated program against the same input in the native engine.
const cases: Array<{ name: string; source: string; files?: Record<string, string> }> = [
  {
    name: 'instance field retains outer capture before defaults',
    source:
      'const outside=99;class Box{#field=outside;constructor(outside=1){this.saved=outside}read(){return[this.#field,this.saved]}}console.log(JSON.stringify(new Box().read()));',
  },
  {
    name: 'static private field uses actual class receiver',
    source: 'class Box{static #field=7;static read(){return this.#field}}console.log(Box.read());',
  },
  {
    name: 'compound write preserves RHS order',
    source:
      "const events=[];class Box{#value=1;add(){return this.#value+=(events.push('rhs'),2)}read(){return this.#value}}const box=new Box();console.log(JSON.stringify([box.add(),box.read(),events]));",
  },
  {
    name: 'private prefix postfix and dropped update',
    source:
      'class Box{#value=1;post(){return this.#value++}pre(){return ++this.#value}drop(){this.#value++}read(){return this.#value}}const box=new Box();console.log(box.post(),box.pre());box.drop();console.log(box.read());',
  },
  {
    name: 'optional private field chain',
    source:
      'class Box{#value=7;read(other){return other?.#value}}const box=new Box();console.log(box.read(box),box.read(null));',
  },
  {
    name: 'loop static private storage is per evaluation',
    source:
      'const out=[];for(let index=0;index<3;index++){class Box{static #value=index;static read(){return this.#value}}out.push(()=>Box.read())}console.log(JSON.stringify(out.map(read=>read())));',
  },
  {
    name: 'private method brand and field before defaults',
    source:
      'class Box{#field=7;#read(){return this.#field}constructor(value=this.#read()){this.saved=value}read(){return this.saved}}console.log(new Box().read());',
  },
  {
    name: 'derived fields retain super and default order',
    source:
      "const events=[];class Base{constructor(){events.push('base')}}class Box extends Base{#field=(events.push('field'),7);constructor(value=(events.push('param'),1)){super();events.push('body');this.saved=value}read(){return[this.#field,this.saved]}}console.log(JSON.stringify([new Box().read(),events]));",
  },
  {
    name: 'anonymous class static private field factory',
    source:
      'const factory=()=>class{static #value=7;static read(){return this.#value}};const First=factory(),Second=factory();console.log(First.read(),Second.read(),First!==Second);',
  },
  {
    name: 'private accessor and field agree on lowering',
    source:
      'class Box{#field=7;get #value(){return this.#field}set #value(value){this.#field=value}read(){this.#value=9;return this.#value}}console.log(new Box().read());',
  },
];

describe('common private lowering plan preserves partial-target semantics', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });
  for (const fixture of cases) {
    for (const target of ['chrome80', 'edge80', 'node12', 'safari14.1', 'chrome84', 'es2022']) {
      const modes = [[], ['--minify-identifiers'], ['--minify']];
      if (target === 'chrome80') {
        for (const lowering of [
          '--use-define-for-class-fields=false',
          '--experimental-decorators',
        ]) {
          modes.push([lowering], [lowering, '--minify-identifiers'], [lowering, '--minify']);
        }
      }
      for (const bundle of [false, true]) {
        for (const flags of modes) {
          test(`${fixture.name} ${target} ${bundle ? 'bundle' : 'standalone'} ${flags.join(' ') || 'plain'}`, async () => {
            const created = await createFixture({ ...fixture.files, 'input.cjs': fixture.source });
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
                ...flags,
                '-o',
                output,
              ],
              { encoding: 'utf8', env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
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
