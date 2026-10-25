import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

const cli = process.env.ZNTC_NATIVE_PARAMETER_ARROW_CLI ?? ZNTC_BIN;
const cases = [
  {
    name: 'simple native default capture',
    source:
      'function Parent(get=()=>new.target){return get}console.log(Parent()()===undefined,new Parent()()===Parent,Parent().name);',
  },
  {
    name: 'arrow native parameter expression capture',
    source:
      'function Parent(get=(value=new.target)=>value){return get}console.log(Parent()()===undefined,new Parent()()===Parent);',
  },
  {
    name: 'nested arrow captures use different wrappers',
    source:
      'function Parent(get=()=>()=>new.target){return get}console.log(Parent()()()===undefined,new Parent()()()===Parent);',
  },
  {
    name: 'nested default arrow retains own name',
    source:
      'function Parent(get=(read=()=>new.target)=>read){return get}console.log(Parent()()()===undefined,new Parent()()()===Parent,Parent()().name);',
  },
  {
    name: 'native arrow parameter closure retains its environment',
    source:
      'function Parent(get=(value=new.target)=>()=>value){return get}console.log(Parent()()()===undefined,new Parent()()()===Parent);',
  },
  {
    name: 'outer capture-like source parameter stays distinct',
    source:
      'function Parent(_newTarget=11,get=()=>[new.target,_newTarget]){return get}const result=new Parent()();console.log(result[0]===Parent,result[1]);',
  },
  {
    name: 'own capture-like arrow parameter stays distinct',
    source:
      'function Parent(get=(_newTarget=11)=>[new.target,_newTarget]){return get}const result=new Parent()();console.log(result[0]===Parent,result[1]);',
  },
  {
    name: 'block capture uses actual block scope',
    source:
      'function Parent(get=()=>{let local=1;{const value=new.target;return[value,local]}}){return get}const result=new Parent()();console.log(result[0]===Parent,result[1]);',
  },
  {
    name: 'derived class capture precedes super safely',
    source:
      'class Base{}class Box extends Base{constructor(get=()=>new.target){super();this.get=get}}console.log(new Box().get()===Box);',
  },
  {
    name: 'ordinary function resets lexical new target boundary',
    source:
      'function Parent(get=()=>function Own(){return new.target}){return get}const Own=Parent()();console.log(Own()===undefined,new Own()===Own);',
  },
  {
    name: 'proto-named parameter retains function name',
    source:
      'function Parent(__proto__=()=>new.target){return __proto__}console.log(Parent().name,new Parent()()===Parent);',
  },
  {
    name: 'literal eval keeps capture-like source parameter',
    source:
      "function Parent(_newTarget=11,get=()=>{eval('1');return[new.target,_newTarget]}){return get}const result=new Parent()();console.log(result[0]===Parent,result[1]);",
  },
  {
    name: 'class heritage is evaluated in enclosing arrow context',
    source:
      'function Parent(get=()=>class extends (new.target||Object){}){return get}console.log(Object.getPrototypeOf(new Parent()())===Parent);',
  },
  {
    name: 'class computed key uses enclosing arrow context',
    source:
      "function Parent(get=()=>class{[new.target===Parent?'yes':'no'](){return 7}}){return get}const Result=new Parent()();console.log(new Result().yes());",
  },
  {
    name: 'arraydefault named parameter default',
    source:
      'function Parent(get=([read=()=>new.target]=[])=>read){return get}console.log(Parent()().name,new Parent()()()===Parent)',
  },
  {
    name: 'objectdefault named parameter default',
    source:
      'function Parent(get=({read=()=>new.target}={})=>read){return get}console.log(Parent()().name,new Parent()()()===Parent)',
  },
  {
    name: 'escapedname named parameter default',
    source:
      'function Parent(get=(r\\u0065ad=()=>new.target)=>read){return get}console.log(Parent()().name,new Parent()()()===Parent)',
  },
];

describe('native parameter arrow reference birth', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });
  for (const fixture of cases) {
    // RN flags affect bundling; standalone currently ignores this target.
    for (const version of ['0.80', '0.84']) {
      for (const mode of [[], ['--minify-identifiers'], ['--minify']]) {
        test(`${fixture.name} RN${version} ${mode.join(' ') || 'plain'}`, async () => {
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
              '--bundle',
              '--platform=react-native',
              `--rn-version=${version}`,
              '--format=cjs',
              ...mode,
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
});
