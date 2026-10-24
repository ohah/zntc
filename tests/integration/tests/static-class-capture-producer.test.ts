import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { readFileSync } from 'node:fs';
import { createFixture, runZntc } from './helpers';

const cases = [
  {
    name: 'class-self compound write evaluates RHS before readonly throw',
    source:
      'const log=[];class Box {static read=()=>{try{Box+={valueOf(){log.push("rhs");return 1;}};}catch(error){log.push(error.name);}};} Box.read();console.log(log.join(","));',
  },
  {
    name: 'class-self update performs primitive conversion before readonly throw',
    source:
      'const log=[];class Box {static read=()=>{try{Box++;}catch(error){log.push(error.name);}};} Box[Symbol.toPrimitive]=()=>{log.push("primitive");return 1;};Box.read();console.log(log.join(","));',
  },
  {
    name: 'class-self destructuring evaluates getter before readonly throw',
    source:
      'const log=[];class Box {static read=()=>{try{({value:Box}={get value(){log.push("get");return 1;}});}catch(error){log.push(error.name);}};}Box.read();console.log(log.join(","));',
  },
  {
    name: 'native class-self write stays readonly',
    source:
      'class Box {static read=()=>{try{Box=1;return "bad";}catch(error){return error.name;}};} console.log(Box.read());',
  },
  {
    name: 'reassigned outer class',
    source:
      'class Box { static value=1; static read=()=>this.value; } const original=Box; Box={value:99}; console.log(original.read());',
  },
  {
    name: 'arrow parameter shadows declaration',
    source:
      'class Box { static value=2; static read=Box=>this.value; } console.log(Box.read({value:99}));',
  },
  {
    name: 'source class self remains immutable',
    source:
      'class Box { static value=3; static read=()=>Box.value; } const original=Box; Box={value:99}; console.log(original.read());',
  },
  {
    name: 'loop evaluates distinct captures',
    source:
      'const readers=[]; for(let i=0;i<3;i++){ class Box { static value=i; static read=()=>this.value; } readers.push(Box.read); } console.log(readers.map(read=>read()).join(","));',
  },
  {
    name: 'factory evaluates distinct captures',
    source:
      'function make(n){ class Box { static value=n; static read=()=>this.value; } return Box.read; } const a=make(4),b=make(5); console.log(a(),b(),a());',
  },
  {
    name: 'nested same name owners',
    source:
      'class Box { static value=6; static make=()=>{class Box {static value=7;static read=()=>this.value;} return [this.value,Box.read()];};} const original=Box;Box={value:99};console.log(original.make().join(","));',
  },
  {
    name: 'nested computed key keeps outer this',
    source:
      'class Box { static value="key"; static inner=class Box { [this.value](){return 8;} static read=()=>this; };} console.log(new Box.inner().key(),Box.inner.read()===Box.inner);',
  },
  {
    name: 'generated source alias collision',
    source:
      'const _classThis=99,_classThis2=98; class Box { static value=9; static read=()=>this.value+_classThis-_classThis2; } console.log(Box.read());',
  },
  {
    name: 'named expression shadow and reassignment',
    source:
      'let Outer=class Inner {static value=10;static read=Inner=>this.value;static self=()=>Inner.value;};const original=Outer;Outer={value:99};console.log(original.read({value:99}),original.self());',
  },
  {
    name: 'static super receiver after reassignment',
    source:
      'class Base {static get value(){return this.extra;}} class Box extends Base {static extra=11;static read=()=>super.value;} const original=Box;Box={extra:99};console.log(original.read());',
  },
];

describe('static class captures keep per-evaluation identity (#4819)', () => {
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
            if (target === 'es5') expect(readFileSync(output, 'utf8')).not.toMatch(/\bconst\b/);
            const executed = spawnSync('node', [output], { encoding: 'utf8' });
            expect(executed.status, executed.stderr).toBe(0);
            expect(executed.stdout).toBe(native.stdout);
          });
        }
      }
    }
  }
});
