import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

const cli = process.env.ZNTC_NATIVE_PRIVATE_INITIALIZER_CLI ?? ZNTC_BIN;
// The surrounding .cjs remains sloppy; class-derived functions remain strict.
// Compare each generated program against the same input in the native engine.
const cases: Array<{ name: string; source: string; files?: Record<string, string> }> = [
  {
    name: 'private field value initializes before native default',
    source:
      'class Box{#field=7;constructor(value=this.#field){this.saved=value}}console.log(new Box().saved);',
  },
  {
    name: 'private method reads initialized private field in default',
    source:
      'class Box{#field=7;#read(){return this.#field}constructor(value=this.#read()){this.saved=value}}console.log(new Box().saved);',
  },
  {
    name: 'private getter observes initialization before default',
    source:
      "const events=[];class Box{#field=(events.push('field'),7);get #read(){events.push('get');return this.#field}constructor(value=this.#read){events.push('body');this.saved=value}}console.log(JSON.stringify([new Box().saved,events]));",
  },
  {
    name: 'private initializer captures outer constructor shadow',
    source:
      'const outside=99;class Box{#field=outside;constructor(outside=1,value=this.#field){this.saved=[outside,value]}}console.log(JSON.stringify(new Box().saved));',
  },
  {
    name: 'private initializer getter runs before default side effects',
    source:
      "const events=[];const input={get value(){events.push('get');return 7}};class Box{#field=(events.push('field'),input.value);constructor(value=(events.push('param'),this.#field)){events.push('body');this.saved=value}}console.log(JSON.stringify([new Box().saved,events]));",
  },
  {
    name: 'private closure retains outer value across body var',
    source:
      'const value=99;class Box{#read=()=>value;constructor(value=1,read=this.#read){this.read=read;var value=9;this.saved=value}}const box=new Box();console.log(box.read(),box.saved);',
  },
  {
    name: 'forward default closure sees later private-derived cell',
    source:
      'class Box{#field=7;constructor(get=()=>value,value=this.#field){this.get=get}}console.log(new Box().get());',
  },
  {
    name: 'prefix default TDZ retains field side effect',
    source:
      "const events=[];class Box{#field=(events.push('field'),7);constructor(first=(()=>value)(),value=this.#field){events.push('body')}}try{new Box()}catch(error){events.push(error.name)}console.log(JSON.stringify(events));",
  },
  {
    name: 'prefix write TDZ retains field and RHS order',
    source:
      "const events=[];class Box{#field=(events.push('field'),7);constructor(first=(()=>{events.push('rhs');value=9})(),value=this.#field){events.push('body')}}try{new Box()}catch(error){events.push(error.name)}console.log(JSON.stringify(events));",
  },
  {
    name: 'throwing private initializer precedes default effects',
    source:
      "const events=[];class Box{#field=(()=>{events.push('field');throw Error('field')})();constructor(value=(events.push('param'),7)){events.push('body')}}try{new Box()}catch(error){events.push(error.message)}console.log(JSON.stringify(events));",
  },
  {
    name: 'derived private initializer follows super and parameters',
    source:
      "const events=[];class Base{constructor(){events.push('base')}}class Box extends Base{#field=(events.push('field'),7);constructor(get=(events.push('param'),()=>this.#field)){super();events.push('body');this.get=get}}console.log(JSON.stringify([new Box().get(),events]));",
  },
  {
    name: 'blank private field keeps native undefined and arity',
    source:
      'class Box{#field;constructor(value=this.#field){this.saved=value}}console.log(new Box().saved,Box.length);',
  },
  {
    name: 'static private initializer does not move instance defaults',
    source:
      'class Box{static #field=7;constructor(value=Box.#field){this.saved=value}}console.log(new Box().saved,Box.length);',
  },
];

describe('native private initializer parameter timing', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });
  for (const fixture of cases) {
    for (const target of ['chrome84', 'es2022']) {
      for (const bundle of [false, true]) {
        const modes: string[][] = [];
        for (const lowering of [
          [],
          ['--use-define-for-class-fields=false'],
          ['--experimental-decorators'],
          ['--experimental-decorators', '--use-define-for-class-fields=true'],
        ]) {
          modes.push(lowering, [...lowering, '--minify-identifiers'], [...lowering, '--minify']);
        }
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
