import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

const cli = process.env.ZNTC_CLASS_PARAMETER_CELLS_CLI ?? ZNTC_BIN;
// The surrounding .cjs remains sloppy; class-derived functions remain strict.
// Compare each generated program against the same input in the native engine.
const cases: Array<{ name: string; source: string; files?: Record<string, string> }> = [
  {
    name: 'constructor forward closure',
    source:
      'let saved;const Box=class{constructor(get=()=>value,{...value}={n:7}){saved=get;}};new Box();console.log(saved().n);',
  },
  {
    name: 'outer binding shadow',
    source:
      'const value={n:99};let saved;class Box{constructor(get=()=>value,{...value}={n:7}){saved=get;}}new Box();console.log(saved().n,value.n);',
  },
  {
    name: 'body var shadow',
    source:
      'let saved;class Box{constructor(get=()=>value,{...value}={n:7}){saved=get;var value={n:9};this.value=value;}}const box=new Box();console.log(saved().n,box.value.n);',
  },
  {
    name: 'later default sees copied rest',
    source:
      'const input={n:7};let saved;class Box{constructor(get=()=>value,{...value}=input,after=value){saved=()=>[get()===value,after===value,value===input];}}new Box();console.log(JSON.stringify(saved()));',
  },
  {
    name: 'derived constructor lexical captures',
    source:
      'let saved;class Base{}class Box extends Base{constructor(get=()=>[value.n,arguments[1].n,new.target===Box,this.token],{...value}={n:7}){super();this.token=2;saved=get;}}new Box(undefined,{n:7});console.log(JSON.stringify(saved()));',
  },
  {
    name: 'base fields initialize before defaults',
    source:
      'const events=[];class Box{token=(events.push("field"),2);constructor(get=()=>[value.n,this.token],{...value}=(events.push("param"),{n:7})){events.push("body");this.saved=get;}}const box=new Box();console.log(JSON.stringify([box.saved(),events]));',
  },
  {
    name: 'derived fields follow super after defaults',
    source:
      'const events=[];class Base{constructor(){events.push("base")}}class Box extends Base{token=(events.push("field"),2);constructor(get=()=>[value.n,this.token],{...value}=(events.push("param"),{n:7})){events.push("before");super();events.push("after");this.saved=get;}}const box=new Box();console.log(JSON.stringify([box.saved(),events]));',
  },
  {
    name: 'method prefix TDZ read',
    source:
      'const value={n:99};class Box{read(first=(()=>value)(),{...value}={n:7}){return first}}try{new Box().read();console.log("body")}catch(e){console.log(e.name)}console.log(value.n);',
  },
  {
    name: 'static method prefix TDZ write',
    source:
      'const events=[];let value={n:99};class Box{static read(first=(()=>{events.push("rhs");value={n:9}})(),{...value}={n:7}){events.push("body")}}try{Box.read()}catch(e){events.push(e.name)}events.push(value.n);console.log(JSON.stringify(events));',
  },
  {
    name: 'method home object and lexical captures',
    source:
      'class Base{read(){return this.token}}class Box extends Base{method(get=()=>[super.read(),value.n,arguments[1].n,new.target],{...value}={n:7}){return get}}const box=new Box();box.token=2;console.log(JSON.stringify(box.method(undefined,{n:7})()));',
  },
  {
    name: 'default ordinary function retains class strictness',
    source:
      'class Box{static read(get=function(){let poison;try{arguments.callee}catch(e){poison=e.name}return[value.n,this===undefined,arguments.length,poison]},{...value}={n:7}){return get}}console.log(JSON.stringify(Box.read()()));',
  },
  {
    name: 'instance setter retains one strict formal',
    source:
      'class Box{set value({...value}){let poison;try{arguments.callee}catch(e){poison=e.name}this.saved=[value.n,poison,Object.getOwnPropertyDescriptor(Box.prototype,"value").set.length];}}const box=new Box();box.value={n:7};console.log(JSON.stringify(box.saved));',
  },
  {
    name: 'static setter retains one strict formal',
    source:
      'class Box{static set value({...value}){this.saved=[value.n,Object.getOwnPropertyDescriptor(Box,"value").set.length];}}Box.value={n:7};console.log(JSON.stringify(Box.saved));',
  },
  {
    name: 'sloppy object setter remains valid',
    source:
      'const object={set value({...value}){this.saved=[value.n,Object.getOwnPropertyDescriptor(object,"value").set.length];}};object.value={n:7};console.log(JSON.stringify(object.saved));',
  },
  {
    name: 'base default observes initialized public field',
    source:
      'class Box{field=7;constructor(value=this.field){this.saved=value}}console.log(new Box().saved);',
  },
  {
    name: 'base default observes initialized private field',
    source:
      'class Box{#field=7;constructor(value=this.#field){this.saved=value}}console.log(new Box().saved);',
  },
  {
    name: 'base default observes installed private method brand',
    source:
      'class Box{#read(){return 7}constructor(value=this.#read()){this.saved=value}}console.log(new Box().saved);',
  },
  {
    name: 'static fields do not move constructor defaults',
    source:
      'const events=[];class Box{static field=events.push("static");constructor(value=(events.push("param"),7)){events.push("body");this.saved=value}}const box=new Box();console.log(JSON.stringify([box.saved,events]));',
  },
  {
    name: 'static named constructor remains ordinary method',
    source:
      'const events=[];class Box{field=events.push("instance");static constructor(value=(events.push("param"),7)){return value}}console.log(JSON.stringify([Box.constructor(),events]));',
  },
  {
    name: 'constructor cell lifetime is per invocation',
    source:
      'class Box{field=7;constructor(get=()=>value,{...value}={n:7}){this.get=get}}const one=new Box(undefined,{n:1}),two=new Box(undefined,{n:2});console.log(one.get().n,two.get().n);',
  },
  {
    name: 'static constructor name does not replace implicit constructor',
    source:
      'class Box{#field=7;static constructor({a,...rest}={a:1,b:2}){return rest.b}read(){return this.#field}}console.log(new Box().read(),Box.constructor());',
  },
  {
    name: 'escaped constructor key retains its actual role',
    source:
      'class Box{#field=7;constr\\u0075ctor(value=this.#field){this.saved=value}}console.log(new Box().saved);',
  },
  {
    name: 'field captures outer binding before parameter cells',
    source:
      'const outside=99;class Box{field=outside;constructor(outside=1){this.saved=outside}}const box=new Box();console.log(JSON.stringify([box.field,box.saved]));',
  },
  {
    name: 'safe literal eval in moved field preserves initialization order',
    source:
      'class Box{field=eval("1+2");constructor(value=this.field){this.saved=value}}console.log(new Box().saved);',
  },
  {
    name: 'safe this eval in moved field preserves receiver',
    source:
      'class Box{field=eval("this");constructor(value=this.field){this.saved=value}}const box=new Box();console.log(box.saved===box);',
  },
  {
    name: 'ordinary constructor-named object method retains own new target',
    source:
      'class Box{field={constructor(value=()=>new.target,{...rest}={n:7}){return[value()===undefined,rest.n]}}}console.log(JSON.stringify(new Box().field.constructor()));',
  },
  {
    name: 'computed constructor key remains an ordinary method',
    source:
      "class Box{#field=7;['constructor'](value=2){return value}read(){return this.#field}}const box=new Box();console.log(box.read(),box.constructor());",
  },
];

describe('native class parameter cells preserve initialization environments', () => {
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
