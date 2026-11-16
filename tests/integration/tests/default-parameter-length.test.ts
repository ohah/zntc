import { describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN as defaultBinary } from './helpers';

// Only the CLI is consumed. ZNTC_BIN permits the exact same tests to compare a
// sealed baseline and candidate without rebuilding or replacing an addon.
const binary = process.env.ZNTC_BIN ?? defaultBinary;
const node = process.env.NODE_BIN ?? 'node';
const fixtures: { name: string; source: string; lengths?: number[] }[] = [
  {
    name: 'setter retains native callable ABI while restoring its arity',
    source:
      'const object={set value(v=42){this.seen=v;return v+1}};const setter=Object.getOwnPropertyDescriptor(object,"value").set;const receiver={};const returned=setter.call(receiver,undefined);let construct;try{new setter();construct="ok"}catch(e){construct=e.name}const d=Object.getOwnPropertyDescriptor(setter,"length");console.log(JSON.stringify({lengths:[setter.length],values:[receiver.seen,returned,setter.name,Object.prototype.hasOwnProperty.call(setter,"prototype"),construct,[d.value,d.writable,d.enumerable,d.configurable]]}));',
  },
  {
    name: 'first default determines six callable lengths',
    source:
      'function first(a=1,b){}function later(a,b=2,c){}const arrow=(a=1,b)=>a;const object={method(a=1,b){return a}};class C{constructor(a=1,b){this.a=a}}function* generator(a=1,b){yield a}console.log(JSON.stringify({lengths:[first.length,later.length,arrow.length,object.method.length,C.length,generator.length],values:[arrow(),object.method(),new C().a,generator().next().value]}));',
    lengths: [0, 1, 0, 0, 0, 0],
  },
  {
    name: 'arrow-lexical',
    source:
      'function observe(){let result;function outer(seed){const f=(a=this.seed,b=arguments[0])=>[a,b,this.seed,arguments.length];return [f.length,f(),f(5,6)]}const v=outer.call({seed:40},2);result={lengths:[v[0]],values:v.slice(1)};console.log(JSON.stringify(result));}observe();\n',
  },
  {
    name: 'constructor-prototype',
    source:
      'function observe(){let result;function C(a=1,b){this.a=a;this.b=b;this.target=new.target===C}const a=new C(undefined,2);result={lengths:[C.length],values:[a.a,a.b,a.target,a instanceof C,Object.getPrototypeOf(a)===C.prototype,C.prototype.constructor===C]};console.log(JSON.stringify(result));}observe();\n',
  },
  {
    name: 'class-constructors',
    source:
      'function observe(){let result;class B{constructor(a=1,b){this.v=[a,b]}}class D extends B{constructor(a,b=2,c){super(a,b);this.c=c}}let d=new D(3,undefined,4);result={lengths:[B.length,D.length],values:[d.v,d.c,d instanceof D,d instanceof B,Object.getPrototypeOf(D.prototype)===B.prototype]};console.log(JSON.stringify(result));}observe();\n',
  },
  {
    name: 'generator-async',
    source:
      'async function observe(){let result;function* g(a=1,b){yield a;return b}async function f(a,b=2){return [a,b]}async function* h(a=3){yield a}const it=g(undefined,4),ai=h();result={lengths:[g.length,f.length,h.length],values:[it.next(),it.next(),await f(1),await ai.next(),await ai.next()]};console.log(JSON.stringify(result));}observe().catch(e=>{console.error(e);process.exitCode=1});\n',
  },
  {
    name: 'parameter defaults precede body var scope',
    // The closure+minify corpus has an independent baseline semantic-refresh
    // error, archived under issue evidence. This isolates the same body-scope
    // boundary with baseline values intact and only Function.length wrong.
    source:
      'let x=40;function f(a=x,b){var x=99;return[a,b,x]}console.log(JSON.stringify({lengths:[f.length],values:[f(undefined,2),f()]}));',
  },
  {
    name: 'destructuring-order',
    source:
      "function observe(){let result;let log=[];function f(a=(log.push('a'),1),{x}=(log.push('object'),{x:a+1}),...rest){return [a,x,rest,log]}result={lengths:[f.length],values:[f(undefined,undefined,3,4)]};console.log(JSON.stringify(result));}observe();\n",
  },
  {
    name: 'order-this-only',
    source:
      'function observe(){let result;const log=[];function f(a=(log.push("a"),this.seed),b=(log.push("b"),a+1),c){log.push("body");return [a,b,c,this.seed]}result={lengths:[f.length],values:[f.call({seed:40}),f.call({seed:9},undefined,5,8),log]};console.log(JSON.stringify(result));}observe();\n',
  },
  {
    name: 'strict-arguments',
    source:
      '"use strict";\nfunction observe(){let result;function f(a=1,b){a=7;arguments[1]=9;return [a,b,arguments[0],arguments[1],arguments.length]}function g(a,b=1){a=7;arguments[1]=9;return [a,b,arguments[0],arguments[1],arguments.length]}result={lengths:[f.length,g.length],values:[f(3,4),g(3,4),f()]};console.log(JSON.stringify(result));}observe();\n',
  },
  {
    name: 'tail parameters snapshot before arguments mutations',
    source:
      '"use strict";function f(a=1,b,c){arguments[1]=8;arguments[2]=9;return [a,b,c,arguments[1],arguments[2],arguments.length]}console.log(JSON.stringify({lengths:[f.length],values:[f(undefined,2,3),f()]}));',
  },
  {
    name: 'missing tail does not read indexed prototype getter',
    source:
      "\"use strict\";let reads=0,result;function f(a=1,b){return [a,b,arguments[1]]}const old=Object.getOwnPropertyDescriptor(Object.prototype,'1');try{Object.defineProperty(Object.prototype,'1',{configurable:true,get(){reads++;return 77}});result=[f(),f(undefined,5)];}finally{if(old)Object.defineProperty(Object.prototype,'1',old);else delete Object.prototype[1];}console.log(JSON.stringify({lengths:[f.length],values:[result,reads]}));",
  },
  {
    name: 'Source arguments parameter does not replace tail argument inputs',
    // Body var/function/let `arguments` variants already fail baseline graph
    // refresh; use the actual Source parameter binding as the arity regression.
    source:
      'function f(arguments=1,b){return[arguments,b]}console.log(JSON.stringify({lengths:[f.length],values:[f(undefined,2),f()]}));',
  },
  {
    name: 'early calls preserve callable identity and length descriptor',
    source:
      '"use strict";const early=[f.length,f(undefined,3)];function f(a=1,b){return [a,b]}const descriptor=Object.getOwnPropertyDescriptor(f,\'length\');console.log(JSON.stringify({lengths:[f.length],values:[early,[descriptor.value,descriptor.writable,descriptor.enumerable,descriptor.configurable],f.prototype.constructor===f,Object.getPrototypeOf(new f())===f.prototype]}));',
  },
  {
    name: 'setter default has length zero with one physical parameter',
    source:
      "const values=[];const object={set value(v=42){values.push(v)}};const setter=Object.getOwnPropertyDescriptor(object,'value').set;object.value=undefined;object.value=7;console.log(JSON.stringify({lengths:[setter.length],values:values}));",
  },
];

function execute(file: string) {
  return spawnSync(node, [file], { encoding: 'utf8' });
}

async function checkFixture(
  fixture: (typeof fixtures)[number],
  target: string,
  minify: boolean,
  keepNames: boolean,
) {
  const { dir, cleanup } = await createFixture({ 'main.cjs': fixture.source });
  try {
    const input = join(dir, 'main.cjs');
    const output = join(dir, 'compiled.cjs');
    const native = execute(input);
    expect(native.status, native.stderr).toBe(0);
    expect(native.stderr).toBe('');
    const expected = JSON.parse(native.stdout);
    if (fixture.lengths) expect(expected.lengths).toEqual(fixture.lengths);
    const built = spawnSync(
      binary,
      [
        '--bundle',
        input,
        '--platform=node',
        '--format=cjs',
        `--target=${target}`,
        ...(minify ? ['--minify'] : []),
        ...(keepNames ? ['--keep-names'] : []),
        '-o',
        output,
      ],
      { encoding: 'utf8' },
    );
    expect(built.status, built.stderr).toBe(0);
    expect(built.stderr).toBe('');
    const actual = execute(output);
    expect(actual.status, actual.stderr).toBe(0);
    expect(actual.stderr).toBe('');
    expect(JSON.parse(actual.stdout)).toEqual(expected);
  } finally {
    await cleanup();
  }
}

describe('#6975 default parameters preserve Function.length and parameter evaluation', () => {
  for (const fixture of fixtures)
    for (const target of ['esnext', 'es5'])
      for (const minify of [false, true])
        for (const keepNames of [false, true])
          test(`${fixture.name} target=${target} minify=${minify} keepNames=${keepNames}`, () =>
            checkFixture(fixture, target, minify, keepNames));
});

// Dynamic-scope controls already match baseline values/lengths. They preserve
// that behavior; these tests do not claim new eval/with downlevel support.
for (const fixture of [
  {
    name: 'direct eval',
    source:
      'function f(a=1,b){return eval("[a,b]")}console.log(JSON.stringify({lengths:[f.length],values:[f(undefined,2),f()]}));',
  },
  {
    name: 'with scope',
    source:
      'function f(a=1,b){with({x:40})return[a,b,x]}console.log(JSON.stringify({lengths:[f.length],values:[f(undefined,2),f()]}));',
  },
])
  for (const target of ['esnext', 'es5'])
    for (const minify of [false, true]) {
      test(`#6975 unchanged dynamic scope: ${fixture.name} target=${target} minify=${minify}`, () =>
        checkFixture(fixture, target, minify, false));
    }

// Function.length does not permit changing setter grammar, and a directive in
// a non-simple parameter body is an early error rather than a lowering input.
for (const [name, source] of [
  ['setter without a parameter', 'const object={set value(){}};'],
  ['setter with two parameters', 'const object={set value(a,b){}};'],
  ['strict directive with a default parameter', 'function f(a=1){"use strict";return a}'],
]) {
  test(`#6975 rejects invalid Source: ${name}`, async () => {
    const { dir, cleanup } = await createFixture({ 'invalid.cjs': source });
    try {
      const input = join(dir, 'invalid.cjs');
      const native = spawnSync(node, ['--check', input], { encoding: 'utf8' });
      expect(native.status).not.toBe(0);
      for (const target of ['esnext', 'es5']) {
        const built = spawnSync(
          binary,
          [
            '--bundle',
            input,
            '--platform=node',
            '--format=cjs',
            `--target=${target}`,
            '-o',
            join(dir, `${target}.cjs`),
          ],
          { encoding: 'utf8' },
        );
        expect(built.status).not.toBe(0);
        expect(built.stderr.length).toBeGreaterThan(0);
      }
    } finally {
      await cleanup();
    }
  });
}

// Parameter bindings snapshot the call's input list before any default runs.
// Mutating the arguments object during initialization must not replace either
// a trailing input or the retained prefix's originally unmapped binding.
const initializerMutations = [
  {
    name: 'rest retains inputs when a default overwrites an arguments entry',
    source:
      'function f(a=(arguments[1]=99),...r){return[a,r]}console.log(JSON.stringify({lengths:[f.length],values:[f(undefined,42,43),f()]}));',
  },
  {
    name: 'rest retains inputs when a default truncates arguments length',
    source:
      'function f(a=(arguments.length=0),...r){return[a,r]}console.log(JSON.stringify({lengths:[f.length],values:[f(undefined,42,43),f()]}));',
  },
  {
    name: 'rest retains inputs when a default deletes an arguments entry',
    source:
      'function f(a=(delete arguments[1]),...r){return[a,r]}console.log(JSON.stringify({lengths:[f.length],values:[f(undefined,42,43),f()]}));',
  },
  {
    name: 'derived constructor snapshots rest before a default mutates arguments',
    source:
      'class B{constructor(a,b){this.values=[a,b]}}class D extends B{constructor(a=(arguments[1]=99),...r){super(a,r[0])}}console.log(JSON.stringify({lengths:[D.length],values:[new D(undefined,42).values]}));',
  },
  {
    name: 'async generator Source arguments parameter keeps its own cell',
    source:
      'async function* f(arguments=3){yield arguments}f().next().then(function(v){console.log(JSON.stringify({lengths:[f.length],values:[v.value]}))});',
  },
  {
    name: 'default initializer mutates tail entries and arguments length',
    source:
      'function f(a=(arguments[1]=9,arguments.length=0,1),b,c){return[a,b,c,arguments.length,arguments[1]]}console.log(JSON.stringify({lengths:[f.length],values:[f(undefined,2,3),f()]}));',
  },
  {
    name: 'sloppy retained prefix remains unmapped during a default',
    source:
      'function f(a,b=(arguments[0]=9,1)){return[a,b,arguments[0]]}console.log(JSON.stringify({lengths:[f.length],values:[f(3),f()]}));',
  },
  {
    name: 'default arrow mutates lexical arguments after input snapshots',
    source:
      'function f(a,b=(()=>{arguments[0]=9;arguments[2]=10;arguments.length=0;return 1})(),c){return[a,b,c,arguments[0],arguments[2],arguments.length]}console.log(JSON.stringify({lengths:[f.length],values:[f(3,undefined,4),f()]}));',
  },
];
for (const fixture of initializerMutations)
  for (const minify of [false, true]) {
    test(`#6975 initializer input snapshots: ${fixture.name} minify=${minify}`, () =>
      checkFixture(fixture, 'es5', minify, true));
  }
