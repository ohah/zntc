import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

const cli = process.env.ZNTC_PRIVATE_SCOPE_CLI ?? ZNTC_BIN;
const cases = [
  {
    name: 'static descriptor',
    source: 'class Box{static #value=1;static read(){return this.#value;}}console.log(Box.read());',
  },
  {
    name: 'nested same-name arrow',
    source:
      'class Box{static #value=1;static read=()=>{class Box{static #value=2;static read(){return this.#value;}}return Box.read();};}console.log(Box.read());',
  },
  {
    name: 'implicit base constructor',
    source: 'class Box{#value=1;read(){return this.#value;}}console.log(new Box().read());',
  },
  {
    name: 'implicit derived constructor',
    source:
      'class Base{};class Box extends Base{#value=1;read(){return this.#value;}}console.log(new Box().read());',
  },
  {
    name: 'existing non-simple constructor',
    source:
      'class Box{constructor(value=1){this.value=value;}#value=2;read(){return this.#value;}}console.log(new Box().read());',
  },
  {
    name: 'static method descriptor',
    source:
      'class Box{static #read(){return 1;}static run(){return this.#read();}}console.log(Box.run());',
  },
  {
    name: 'instance method initialization',
    source: 'class Box{#read(){return 1;}run(){return this.#read();}}console.log(new Box().run());',
  },
  {
    name: 'static getter descriptor',
    source:
      'class Box{static get #value(){return 1;}static run(){return this.#value;}}console.log(Box.run());',
  },
  {
    name: 'accessor shared brand',
    source:
      'class Box{get #value(){return 1;}set #value(value){this.seen=value;}run(){this.#value=2;return this.#value;}}const b=new Box();console.log(b.run(),b.seen);',
  },
  {
    name: 'computed field and rest constructor',
    source:
      "const _value=9;class Box{#value=1;['arrow']=()=>this.#value;constructor(...args){this.args=args;}}const b=new Box(4);console.log(b.arrow(),b.args.length);",
  },
  {
    name: 'native method default parameter',
    source:
      'class Box{static #value=1;static read(value=this.#value){return value;}}console.log(Box.read());',
  },
  {
    name: 'extracted method default parameter',
    source:
      'class Box{#value=1;#read(value=this.#value){return value;}read(){return this.#read();}}console.log(new Box().read());',
  },
  {
    name: 'captured method default parameter',
    source:
      'class Box{static #value=1;static #read(value=Box.#value){return value;}static read(){return this.#read();}}console.log(Box.read());',
  },
  {
    name: 'static block owner',
    source: 'class Box{static #value=1;static{this.read=this.#value;}}console.log(Box.read);',
  },
  {
    name: 'generator switch owns class private super helpers',
    source:
      "function getBase(){return class Base{get value(){return this.token+':value';}get other(){return this.token+':other';}}}function* build(){class Child extends getBase(){#value(){const Child=1;return super.value;}#other(){return super.other;}method(){return[this.#value(),this.#other()];}}yield Child;}const Child=build().next().value;const child=new Child();child.token='ok';console.log(JSON.stringify(child.method()));",
  },
  {
    name: 'async callback owns class private references',
    source:
      'async function make(){await 0;return class Box{#value=7;read(){return this.#value;}}}make().then(Box=>console.log(new Box().read()));',
  },
  {
    name: 'static method exists before public field initialization',
    source:
      'class Box{static read=this.#method();static #method(){return 9;}}console.log(Box.read);',
  },
  {
    name: 'static method exists before private field initialization',
    source:
      'class Box{static #value=this.#method();static #method(){return 9;}static read(){return this.#value;}}console.log(Box.read());',
  },
  {
    name: 'readonly write-only method',
    source:
      'class Box{static #write(){try{Box=1;}catch(error){return error.name;}}static run(){return this.#write();}}console.log(Box.run());',
  },
];

describe('private references carry creation-time owner identity (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });
  for (const fixture of cases) {
    for (const target of ['es2022', 'es2015', 'es2017', 'es5']) {
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
