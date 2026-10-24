import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntc } from './helpers';

const cases = [
  {
    name: 'ordinary strict arguments keeps callee poison',
    source:
      'class Box{static read=function(){try{return typeof eval("arguments").callee;}catch(error){return error.name;}};}console.log(Box.read());',
    rejects: (target: string) => target !== 'es2022',
    allModes: true,
  },
  {
    name: 'ordinary function eval inherits class strict this',
    source:
      'class Box{static read=function(){return eval("this")};}const read=Box.read;console.log(read()===undefined);',
    rejects: (target: string) => target !== 'es2022',
    allModes: true,
  },
  {
    name: 'ordinary eval var stays isolated in class strict code',
    source:
      'class Box{static read=function(){eval("var local=7");return typeof local;};}console.log(Box.read());',
    rejects: (target: string) => target !== 'es2022',
    allModes: true,
  },
  {
    name: 'legacy numeric eval literal retains strict SyntaxError',
    source:
      'class Box{static read=()=>{try{return eval("010");}catch(error){return error.name;}};}console.log(Box.read());',
    rejects: (target: string) => target !== 'es2022',
    allModes: true,
  },
  {
    name: 'lexically bound eval can contain the builtin',
    source:
      'function run(eval){class Box{static read=()=>eval("this");}console.log(Box.read()===Box);}run(globalThis.eval);',
    rejects: (target: string) => target !== 'es2022',
    allModes: true,
  },
  {
    name: 'different callee name keeps builtin eval indirect',
    source:
      'function run(evaluate){class Box{static read=()=>evaluate("this");}console.log(Box.read()===globalThis);}run(globalThis.eval);',
    rejects: (_target: string) => false,
    allModes: true,
  },
  {
    name: 'lexically bound builtin eval keeps safe numeric literal',
    source:
      'function run(eval){class Box{static read=()=>eval("1+2");}console.log(Box.read());}run(globalThis.eval);',
    rejects: (_target: string) => false,
    allModes: true,
  },
  {
    name: 'hidden lexical this in literal eval',
    source:
      'class Box { static value=7; static read=()=>eval("this.value"); } console.log(Box.read());',
    rejects: (target: string) => target !== 'es2022',
  },
  {
    name: 'dynamic direct eval argument',
    source:
      'class Box { static value=7; static read=source=>eval(source); } console.log(Box.read("this.value"));',
    rejects: (target: string) => target !== 'es2022',
  },
  {
    name: 'immediate initializer eval',
    source: 'class Box { static read=eval("this"); } console.log(Box.read===Box);',
    rejects: (target: string) => target !== 'es2022',
  },
  {
    name: 'safe numeric literal eval',
    source: 'class Box { static read=()=>eval("1+2"); } console.log(Box.read());',
    rejects: (_target: string) => false,
  },
  {
    name: 'ordinary function owns eval this',
    source:
      'class Box { static value=7; static read=function(){return eval("this.value");}; } console.log(Box.read());',
    rejects: (target: string) => target !== 'es2022',
  },
  {
    name: 'method owns eval this',
    source:
      'class Box { static value=7; static read(){return eval("this.value");} } console.log(Box.read());',
    rejects: (_target: string) => false,
  },
  {
    name: 'ordinary function still closes over class self',
    source:
      'class Box { static value=7; static read=function(){return eval("Box.value");}; } const original=Box; Box={value:99}; console.log(original.read());',
    rejects: (target: string) => target !== 'es2022',
  },
  {
    name: 'ordinary function opaque eval can observe class self',
    source:
      'class Box { static value=7; static read=function(source){return eval(source);}; } console.log(Box.read("Box.value"));',
    rejects: (target: string) => target !== 'es2022',
  },
  {
    name: 'ordinary function local-only literal eval',
    source:
      'class Box { static read=function(){const local=7;return eval("local");}; } console.log(Box.read());',
    rejects: (_target: string) => false,
  },
  {
    name: 'eval class-self assignment keeps readonly exception',
    source:
      'class Box { static read=function(){try {eval("Box=1");return "bad";}catch(error){return error.name;}}; } console.log(Box.read());',
    rejects: (target: string) => target !== 'es2022',
  },
  {
    name: 'with and moved lexical arrow',
    source:
      'with({}) { class Box {static value=7;static read=()=>this.value;} console.log(Box.read()); }',
    rejects: (target: string) => target === 'es5',
  },
];

describe('static initializer dynamic environment diagnostics (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });
  for (const fixture of cases) {
    for (const target of ['es5', 'es2015', 'es2017', 'es2022']) {
      for (const bundle of [false, true]) {
        for (const minify of fixture.allModes
          ? [[], ['--minify-identifiers'], ['--minify']]
          : [[]]) {
          test(`${fixture.name}: ${target}, ${bundle ? 'bundle' : 'standalone'}, ${minify.join(' ') || 'plain'}`, async () => {
            const created = await createFixture({ 'input.cjs': fixture.source });
            cleanup = created.cleanup;
            const input = join(created.dir, 'input.cjs');
            const native = spawnSync('node', [input], { encoding: 'utf8' });
            expect(native.status, native.stderr).toBe(0);
            const output = join(created.dir, 'output.cjs');
            const built = await runZntc([
              input,
              `--target=${target}`,
              '--format=cjs',
              ...minify,
              ...(bundle ? ['--bundle', '--platform=node'] : []),
              '-o',
              output,
            ]);
            if (fixture.rejects(target)) {
              expect(built.exitCode).not.toBe(0);
              expect(built.stderr).toContain('ZNTC1505');
            } else {
              expect(built.exitCode, built.stderr).toBe(0);
              expect(built.stderr).not.toContain('ZNTC1505');
              const actual = spawnSync('node', [output], { encoding: 'utf8' });
              expect(actual.status, actual.stderr).toBe(0);
              expect(actual.stdout).toBe(native.stdout);
            }
          });
        }
      }
    }
  }
});
