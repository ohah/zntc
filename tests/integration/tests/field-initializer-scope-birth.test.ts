import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

const cli = process.env.ZNTC_FIELD_INITIALIZER_CLI ?? ZNTC_BIN;
// Computed-key object coercion timing and full-minify computed-method key
// liveness remain separate runtime regressions; the raw 900-cell audit retains
// both inputs and all 37 existing failures. These tests cover initializer moves.
const cases = [
  {
    name: 'implicit base constructor direct source read',
    source: 'const outside=7;class Box{value=outside}console.log(new Box().value);',
  },
  {
    name: 'explicit constructor initialization precedes body',
    source:
      "const events=[];const outside=7;class Box{value=(events.push('field'),outside);constructor(){events.push('body')}}console.log(new Box().value,JSON.stringify(events));",
  },
  {
    name: 'implicit derived constructor receives base result',
    source:
      'const outside=7;class Base{constructor(value){this.base=value}}class Box extends Base{value=outside}const box=new Box(2);console.log(box.value,box.base);',
  },
  {
    name: 'explicit derived field runs after super',
    source:
      "const events=[];const outside=7;class Base{constructor(){events.push('base')}}class Box extends Base{value=(events.push('field'),outside);constructor(){events.push('param');super();events.push('body')}}console.log(new Box().value,JSON.stringify(events));",
  },
  {
    name: 'arrow keeps initializer outer binding across constructor cells',
    source:
      'const outside=7;class Box{value=()=>outside;constructor(outside=1){this.body=outside}}const box=new Box();console.log(box.value(),box.body);',
  },
  {
    name: 'ordinary function keeps own context and outer binding',
    source:
      'const outside=7;class Box{value=function(){return[outside,this===undefined]};constructor(){this.body=1}}const read=new Box().value;console.log(JSON.stringify(read()));',
  },
  {
    name: 'nested class method retains initializer lexical frontier',
    source:
      'const outside=7;class Box{value=class Inner{read(){return outside}};constructor(){this.body=1}}console.log(new(new Box().value)().read());',
  },
  {
    name: 'anonymous class expression initializer arrow',
    source: 'const outside=7;const Box=class{value=()=>outside};console.log(new Box().value());',
  },
  {
    name: 'escaped constructor retains original actual constructor',
    source:
      "const events=[];const outside=7;class Box{value=(events.push('field'),outside);constr\\u0075ctor(){events.push('body')}}console.log(new Box().value,JSON.stringify(events));",
  },
  {
    name: 'string constructor remains actual class constructor',
    source:
      "const events=[];const outside=7;class Box{value=(events.push('field'),outside);'constructor'(){events.push('body')}}console.log(new Box().value,JSON.stringify(events));",
  },
  {
    name: 'static constructor name retains implicit instance constructor',
    source:
      'const outside=7;class Box{value=outside;static constructor(){return 2}}console.log(new Box().value,Box.constructor());',
  },
  {
    name: 'private initializer keeps native declaration and exact outer read',
    source:
      'const outside=7;class Box{#value=outside;read(){return this.#value}}console.log(new Box().read());',
  },
  {
    name: 'blank field define presence keeps initialized sibling',
    source:
      'const outside=7;class Box{empty;value=outside}const box=new Box();console.log(box.value,box.empty);',
  },
  {
    name: 'computed primitive field key retains evaluation before instance initialization',
    source:
      "const events=[];const outside=7;class Box{[(events.push('key'),'value')]=(events.push('field'),outside);constructor(){events.push('body')}}console.log(new Box().value,JSON.stringify(events));",
  },
  {
    name: 'simple constructor parameter cannot shadow initializer binding',
    source:
      'const outside=7;class Box{value=()=>outside;constructor(outside){this.body=outside}}const box=new Box(1);console.log(box.value(),box.body);',
  },
  {
    name: 'constructor body var cannot shadow initializer binding',
    source:
      'const outside=7;class Box{value=()=>outside;constructor(){var outside=9;this.body=outside}}const box=new Box();console.log(box.value(),box.body);',
  },
];

describe('field initializer constructor scope birth', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });
  for (const fixture of cases)
    for (const target of ['es5', 'es2015', 'es2022', 'chrome80', 'chrome84'])
      for (const bundle of [false, true])
        for (const define of [false, true])
          for (const mode of [[], ['--minify-identifiers'], ['--minify']]) {
            test(`${fixture.name} ${target} ${bundle ? 'bundle' : 'standalone'} define=${define} ${mode.join(' ') || 'plain'}`, async () => {
              const created = await createFixture({ 'input.cjs': fixture.source });
              cleanup = created.cleanup;
              const input = join(created.dir, 'input.cjs'),
                output = join(created.dir, 'output.cjs');
              const native = spawnSync('node', [input], { encoding: 'utf8' });
              expect(native.status, native.stderr).toBe(0);
              const built = spawnSync(
                cli,
                [
                  input,
                  `--target=${target}`,
                  '--format=cjs',
                  ...(bundle ? ['--bundle', '--platform=node'] : []),
                  `--use-define-for-class-fields=${define}`,
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
});
