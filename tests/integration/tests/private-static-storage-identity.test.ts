import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { readFileSync } from 'node:fs';
import { createFixture, runZntc } from './helpers';

const cases = [
  {
    name: 'private brand survives outer class reassignment',
    source:
      'class Box{static #value=7;static read=()=>this.#value;}const original=Box;Box={};console.log(original.read());',
  },
  {
    name: 'nested same-spelling classes keep distinct brands',
    source:
      'class Box{static #value=1;static make=()=>{class Box{static #value=2;static read=Box=>this.#value;}return [this.#value,Box.read({})];};}console.log(Box.make().join(","));',
  },
  {
    name: 'moved public initializer exact post reference',
    source: 'class Box{static #value=7;static read=()=>this.#value;}console.log(Box.read());',
  },
  {
    name: 'brand ignores shadowed class spelling',
    source:
      'const Box=class Inner{static #value=7;static read=Inner=>this.#value;};console.log(Box.read({}));',
  },
  {
    name: 'static field loop lifetime',
    source:
      "const readers=[];for(let i=0;i<3;i++){class Box{static #value=i;static read=()=>this.#value;}readers.push(Box.read);}console.log(readers.map(read=>read()).join(','));",
  },
  {
    name: 'instance field loop lifetime',
    source:
      "const instances=[];for(let i=0;i<3;i++){class Box{#value=i;read(){return this.#value;}}instances.push(new Box);}console.log(instances.map(x=>x.read()).join(','));",
  },
  {
    name: 'static method loop lifetime',
    source:
      "const readers=[];for(let i=0;i<3;i++){class Box{static #method(){return i;}static read=()=>this.#method();}readers.push(Box.read);}console.log(readers.map(read=>read()).join(','));",
  },
  {
    name: 'static accessor loop lifetime',
    source:
      "const readers=[];for(let i=0;i<3;i++){class Box{static #value=i;static get #slot(){return this.#value;}static set #slot(v){this.#value=v;}static read=()=>++this.#slot;}readers.push(Box.read);}console.log(readers.map(read=>read()).join(','));",
  },
  {
    name: 'instance captured method loop lifetime',
    source:
      "const instances=[];for(let i=0;i<3;i++){class Box{static value=i;#method(){return Box.value;}read(){return this.#method();}}instances.push(new Box);}console.log(instances.map(x=>x.read()).join(','));",
  },
  {
    name: 'expression loop lifetime',
    source:
      "const readers=[];for(let i=0;i<3;i++){const Box=class Inner{static #value=i;static read=Inner=>this.#value;};readers.push(Box.read);}console.log(readers.map(read=>read({})).join(','));",
  },
  {
    name: 'descriptor before initialization TypeError',
    source:
      "const log=[];class Box{static early=(()=>{try{return this.#value;}catch(e){log.push(e.name);}})();static #value=(log.push('init'),7);static read=()=>this.#value;}console.log(log.join(','),Box.read());",
  },
  {
    name: 'static method exists before field initialization',
    source:
      'class Box{static read=this.#method();static #method(){return 9;}}console.log(Box.read);',
  },
  {
    name: 'generator repeated class evaluation',
    source:
      "function* make(){for(let i=0;i<3;i++){class Box{static #value=i;static read=()=>this.#value;}yield Box.read;}}const readers=[...make()];console.log(readers.map(read=>read()).join(','));",
  },
  {
    name: 'private getter setter and update order',
    source:
      "const log=[];class Box{static #value=1;static get #slot(){log.push('get');return this.#value;}static set #slot(v){log.push('set');this.#value=v;}static read=()=>this.#slot++;}console.log(Box.read(),log.join(','));",
  },
];

describe('private storage keeps exact owner and per-evaluation lifetime (#4819)', () => {
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
            if (target === 'es5') {
              // Private storage is IIFE-owned var; class-self factory aliases
              // have their own readonly contract and are audited separately.
              expect(readFileSync(output, 'utf8')).not.toMatch(
                /\b(?:let|const)\s+_(?:value|slot|method)\b/,
              );
            }
            const executed = spawnSync('node', [output], { encoding: 'utf8' });
            expect(executed.status, executed.stderr).toBe(0);
            expect(executed.stdout).toBe(native.stdout);
          });
        }
      }
    }
  }
});
