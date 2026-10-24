import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { readFileSync } from 'node:fs';
import { createFixture, runZntc } from './helpers';

const cases = [
  {
    name: 'detached-static-function',
    source:
      'class Box{static read=function(){return this===undefined;};}const read=Box.read;console.log(read());',
  },
  {
    name: 'non-simple-parameters',
    source:
      'class Box{static read=function(x=1){return this===undefined;};}const read=Box.read;console.log(read());',
  },
  {
    name: 'arguments-callee',
    source:
      'class Box{static read=function(){try{return arguments.callee===Box.read;}catch(e){return e.name;}};}console.log(Box.read());',
  },
  {
    name: 'function-caller',
    source:
      'class Box{static read=function(){};}try{console.log(Box.read.caller);}catch(e){console.log(e.name);}',
  },
  {
    name: 'initializer-unresolved-write',
    source:
      "try{class Box{static value=(__zntcStrictMissing=1);}console.log('bad');}catch(e){console.log(e.name);}",
  },
  {
    name: 'initializer-readonly-write',
    source:
      "try{class Box{static value=(Object.freeze({}).x=1);}console.log('bad');}catch(e){console.log(e.name);}",
  },
  {
    name: 'static-block-function',
    source:
      'let read;class Box{static{read=function(){return this===undefined;};}}console.log(read());',
  },
  {
    name: 'public-method-function',
    source:
      'class Box{read(){return this===undefined;}}const read=Box.prototype.read;console.log(read());',
  },
  {
    name: 'constructor-nested-function',
    source:
      'class Box{constructor(){console.log((function(){return this===undefined;})());}}new Box();',
  },
  {
    name: 'external-sloppy-function-control',
    source:
      'function outside(){return this===undefined;}class Box{static read=outside;}const read=Box.read;console.log(read());',
  },
  {
    name: 'numeric-control',
    source: 'class Box{static value=1+2;}console.log(Box.value);',
  },
  {
    name: 'plain-write',
    source:
      'class Box{static #f(){try{Box=1;}catch(e){return e.name;}}static read(){return this.#f();}}console.log(Box.read());',
  },
  {
    name: 'compound-write',
    source:
      "const log=[];class Box{static #f(){try{Box+={valueOf(){log.push('rhs');return 1;}};}catch(e){log.push(e.name);}}static read(){return this.#f();}}Box[Symbol.toPrimitive]=()=>{log.push('lhs');return 1;};Box.read();console.log(log.join(','));",
  },
  {
    name: 'update-write',
    source:
      "const log=[];class Box{static #f(){try{Box++;}catch(e){log.push(e.name);}}static read(){return this.#f();}}Box[Symbol.toPrimitive]=()=>{log.push('lhs');return 1;};Box.read();console.log(log.join(','));",
  },
  {
    name: 'destructuring-write',
    source:
      "const log=[];class Box{static #f(){try{({value:Box}={get value(){log.push('get');return 1;}});}catch(e){log.push(e.name);}}static read(){return this.#f();}}Box.read();console.log(log.join(','));",
  },
  {
    name: 'shadow-param-control',
    source:
      'class Box{static #f(Box){Box=1;return Box;}static read(){return this.#f({});}}console.log(Box.read());',
  },
  {
    name: 'captured-read',
    source:
      'class Box{static value=7;static #f(){return Box.value;}static read(){return this.#f();}}const original=Box;Box={value:99};console.log(original.read());',
  },
  {
    name: 'literal-eval-control',
    source:
      "class Box{static #f(){return eval('1+2');}static read(){return this.#f();}}console.log(Box.read());",
  },
  {
    name: 'eval exact class-self after reassignment',
    source:
      "class Box{static value=7;static #f(){return eval('Box');}static read(){return this.#f();}}const original=Box;Box={value:99};console.log(original.read().value);",
  },
  {
    name: 'eval initialized method parameter',
    source:
      "class Box{static #f(local){return eval('local');}static read(){return this.#f(7);}}console.log(Box.read());",
  },
  {
    name: 'eval var before declaration',
    source:
      "class Box{static #f(){return eval('local');var local;}static read(){return this.#f();}}console.log(Box.read());",
  },
  {
    name: 'eval own this',
    source:
      "class Box{static #f(){return eval('this');}static read(){return this.#f();}}console.log(Box.read()===Box);",
  },
  {
    name: 'eval own strict arguments',
    source:
      "class Box{static #f(local){try{return eval('arguments').callee;}catch(e){return e.name;}}static read(){return this.#f(7);}}console.log(Box.read());",
  },
  {
    name: 'escaped parenthesized eval class-self',
    source:
      "class Box{static #f(){return (\\u0065val)('Box');}static read(){return this.#f();}}console.log(Box.read()===Box);",
  },
  {
    name: 'anonymous field function name',
    source: 'class Box{static read=function(){};}console.log(Box.read.name);',
  },
  {
    name: 'anonymous field class name before static effects',
    source:
      'class Box{static Inner=class{static seen=this.name;};}console.log(Box.Inner.name,Box.Inner.seen);',
  },
  {
    name: 'named function parameter environment retains exact class self',
    source:
      'class Box{static value=7;static read=function named(local=Box){return [this,local.value];};}const read=Box.read;Box={value:99};console.log(read()[0]===undefined,read()[1]);',
  },
  {
    name: 'constructor non-simple parameters retain strict context',
    source:
      'const Box=class{constructor({value}={value:7}){console.log((function(){return this===undefined;})(),value);}};new Box();',
  },
  {
    name: 'external sloppy callee control',
    source:
      'function outside(){return arguments.callee===outside;}class Box{static read=outside;}console.log(Box.read());',
  },
];

describe('moved class code keeps strict creation and readonly identity (#4819)', () => {
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
            const native = spawnSync('node', [input], { encoding: 'utf8' });
            expect(native.status, native.stderr).toBe(0);
            const output = join(created.dir, 'output.cjs');
            const built = await runZntc(
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
