import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

const cli = process.env.ZNTC_PARAMETER_CELLS_CLI ?? ZNTC_BIN;
// Sloppy .cjs sources expose arguments/callee and default-function strictness.
// Compare each generated program against the same input in the native engine.
const cases: Array<{ name: string; source: string; files?: Record<string, string> }> = [
  {
    name: 'getter default and body order',
    source:
      "const events=[];const input={get n(){events.push('get');return 7;}};function run(get=()=>value,{...value}=(events.push('rest'),input),after=(events.push('after'),value)){events.push('body');return[get().n,after===value];}console.log(JSON.stringify([run(),events]));",
  },
  {
    name: 'prefix TDZ read shadows outer',
    source:
      "const value={n:99};function run(first=(()=>value)(),{...value}={n:7}){}try{run();console.log('body');}catch(error){console.log(error.name);}console.log(value.n);",
  },
  {
    name: 'prefix TDZ write preserves RHS order',
    source:
      "const events=[];let value={n:99};function run(first=(()=>{events.push('rhs');value={n:9};})(),{...value}={n:7}){events.push('body');}try{run();}catch(error){events.push(error.name);}events.push(value.n);console.log(JSON.stringify(events));",
  },
  {
    name: 'ordinary default function this and arguments',
    source:
      "function run(get=function(){return[value.n,this.tag,arguments.length,arguments.callee===arguments.callee];},{...value}={n:7}){return get;}console.log(JSON.stringify(run().call({tag:2},'x')));",
  },
  {
    name: 'arrow outer arguments and length',
    source:
      "function outer(marker){const invoke=(first,get=()=>[value.n,arguments[0]],{...value}={n:7})=>[get(),invoke.length,first];return invoke(3);}console.log(JSON.stringify(outer('outer')));",
  },
  {
    name: 'ordinary body var split',
    source:
      'let saved;function run(get=()=>value,{...value}={n:7}){saved=get;var value={n:9};return value.n;}console.log(run(),saved().n);',
  },
  {
    name: 'nondefault poison and length',
    source:
      'function run({...value}){try{return [value.n,run.length,arguments.callee]}catch(e){return[value.n,run.length,e.name]}}console.log(JSON.stringify(run({n:7})));',
  },
  {
    name: 'named default class evaluation',
    source:
      'function run(C=class{static name="changed";static seen=this.name},{...value}={n:7}){return[C.name,C.seen,value.n]}console.log(JSON.stringify(run()));',
  },
  {
    name: 'body function shadow',
    source:
      'const value={n:7};function run(get=()=>value,{...rest}={n:8}){function value(){return 9}return[get().n,value(),rest.n]}console.log(JSON.stringify(run()));',
  },
  {
    name: 'trailing native rest and unmapped arguments',
    source:
      'function run(get=()=>value,{...value}={n:7},...tail){arguments[1]={n:9};return[get().n,tail,run.length]}console.log(JSON.stringify(run(undefined,undefined,3,4)));',
  },
  {
    name: 'split shorthand default preserves exclusion key',
    source:
      'function run({a=7,...rest}={},get=()=>a){var a=9;return[get(),a,Object.keys(rest)]}console.log(JSON.stringify(run()));',
  },
  {
    name: 'split computed key preserves evaluation order',
    source:
      'const events=[];function run({[(events.push("key"),"a")]:a,...rest}={a:7,b:8},get=()=>a){var a=9;return[get(),a,Object.keys(rest),events]}console.log(JSON.stringify(run()));',
  },
  {
    name: 'direct import default retains provenance owner',
    source:
      'function run(before=import("./zntc-native-parameter-cells-provenance-dep.mjs"),{...value}={n:8}){return before.then(dep=>[dep.value,value.n]);}run().then(value=>console.log(JSON.stringify(value)));',
    files: {
      'zntc-native-parameter-cells-provenance-dep.mjs': 'export const value=7;',
    },
  },
  {
    name: 'nested default import retains own scope',
    source:
      'function run(get=()=>import("./zntc-native-parameter-cells-provenance-dep.mjs"),{...value}={n:8}){return get().then(dep=>[dep.value,value.n]);}run().then(value=>console.log(JSON.stringify(value)));',
    files: {
      'zntc-native-parameter-cells-provenance-dep.mjs': 'export const value=7;',
    },
  },
];

describe('native parameter cells preserve object-rest environments', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });
  for (const fixture of cases) {
    for (const target of ['es2015', 'es2017', 'es2018', 'es2022']) {
      for (const bundle of [false, true]) {
        for (const flags of [[], ['--minify-identifiers'], ['--minify']]) {
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
