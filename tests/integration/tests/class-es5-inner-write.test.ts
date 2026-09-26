import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntcInDir } from './helpers';

const cases = [
  `const trace=[]; const result=(k,f)=>{try{trace.push([k,f()])}catch(e){trace.push([k,e.name])}};
   let Outer=class Inner {
     static self(){return Inner}
     static assign(){Inner=9} static plus(){return Inner+=1} static post(){return Inner++}
     static preDec(){return --Inner}
     static rhs(){Inner=(trace.push('rhs'),13)}
     static rhsThrow(){Inner=(()=>{trace.push('rhs-throw');throw new RangeError()})()}
     static or(){return Inner||=(trace.push('or-rhs'),9)}
     static and(){return Inner&&=(trace.push('and-rhs'),9)}
     static nullish(){return Inner??=(trace.push('null-rhs'),9)}
     static destruct(){[Inner]=[7]} static loop(){for(Inner of [7]){}}
     method(){Inner=8}
   };
   const saved=Outer;
   for(const k of ['assign','plus','post','preDec','rhs','rhsThrow','or','and','nullish','destruct','loop']) result(k,()=>Outer[k]());
   result('instance',()=>new Outer().method()); Outer=7;
   trace.push(['outer',Outer,saved.self()===saved,saved.name]); console.log(JSON.stringify(trace));`,
  `class Inner { static self(){return Inner} static write(){Inner=2} method(){Inner++} }
   const saved=Inner; let a,b; try{Inner.write()}catch(e){a=e.name}
   try{new saved().method()}catch(e){b=e.name}
   Inner=class Other{}; console.log(JSON.stringify([a,b,saved.self()===saved,Inner.name,saved.name]));`,
  `function make(v){return class Inner {static value(){return Inner} static write(){Inner=v} static update(){++Inner}}}
   const A=make(1),B=make(2); let a,b; try{A.write()}catch(e){a=e.name}
   try{B.update()}catch(e){b=e.name}
   console.log(JSON.stringify([a,b,A.value()===A,B.value()===B,A!==B]));`,
  `const TypeError=function Shadow(){};
   const X=class Inner {static write(){Inner=3}};
   let result;try{X.write()}catch(e){result=[e.name,e instanceof TypeError]}
   console.log(JSON.stringify(result));`,
  `function makeWithShadowedObject(Object){const X=class Inner {constructor(){try{Inner=3}catch(e){this.error=e.name}}};return new X().error}
   console.log(JSON.stringify(makeWithShadowedObject(7)));`,
  `const X=class Inner {constructor(Inner){Inner=7;this.value=Inner} static write(){Inner=8}};
   let result;try{X.write()}catch(e){result=e.name}
   console.log(JSON.stringify([new X(3).value,result]));`,
  `const out=[]; class Inner {static run(){try{({v:Inner}={v:4})}catch(e){out.push(e.name)}
   try{for(Inner in {a:1}){}}catch(e){out.push(e.name)}}}
   Inner.run();console.log(JSON.stringify(out));`,
  `let result;try{class Inner {static value=(Inner=3)}}catch(e){result=e.name}
   console.log(JSON.stringify(result));`,
  `class Inner { field=(Inner=4) }
   let result;try{new Inner()}catch(e){result=e.name}
   console.log(JSON.stringify(result));`,
  `const Inner=class Same {static nested(){return class Same {static write(){Same=3}}} static self(){return Same}};
   const nested=Inner.nested();let result;try{nested.write()}catch(e){result=e.name}
   console.log(JSON.stringify([result,Inner.self()===Inner]));`,
];

describe('ES5 immutable class inner name writes (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const bundle of [false, true]) {
    for (const minify of [false, true]) {
      test(`${bundle ? 'bundle' : 'single'}, ${minify ? 'minify' : 'plain'}`, async () => {
        const fixture = await createFixture({
          'input.mjs': cases.map((source) => `{ ${source} }`).join('\n'),
          'package.json': '{"type":"module"}',
        });
        cleanup = fixture.cleanup;
        const native = spawnSync('node', [join(fixture.dir, 'input.mjs')], { encoding: 'utf8' });
        expect(native.status, native.stderr).toBe(0);
        const output = join(fixture.dir, 'out.mjs');
        const result = await runZntcInDir(fixture.dir, [
          ...(bundle ? ['--bundle', '--platform=node', '--format=esm'] : []),
          'input.mjs',
          '--target=es5',
          ...(minify ? ['--minify-identifiers', '--minify-syntax'] : []),
          '-o',
          output,
        ]);
        expect(result.exitCode, result.stderr).toBe(0);
        const runtime = spawnSync('node', [output], { encoding: 'utf8' });
        expect(runtime.status, runtime.stderr).toBe(0);
        expect(runtime.stdout).toBe(native.stdout);
      });
    }
  }
});
