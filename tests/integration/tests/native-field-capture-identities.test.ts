import { afterAll, expect, test } from 'bun:test';
import { build, buildSync, close } from '../../../packages/core/index';
import { spawnSync } from 'node:child_process';
import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

const cases = [
  [
    'derived body capture before and after super',
    'class Parent{};class Box extends Parent{value=7;constructor(){const early=()=>this;try{console.log(early())}catch(e){console.log(e.name)}super();console.log(early()===this)}}new Box();',
  ],
  [
    'derived shared capture before and after super',
    'class Parent{};class Box extends Parent{value=7;read=()=>this.value;constructor(){const early=()=>this;try{console.log(early())}catch(e){console.log(e.name)}super();console.log(early()===this)}}new Box();',
  ],
  [
    'global alias collision',
    'const _this=11;class Box{value=7;read=()=>[this.value,_this]}console.log(JSON.stringify(new Box().read()));',
  ],
  [
    'native non-simple constructor collision',
    'class Box{value=7;read=()=>this.value;constructor(_this=11){this.other=_this}}const box=new Box();console.log(box.read(),box.other);',
  ],
  ['implicit base', 'class Box{value=7;read=()=>this.value}console.log(new Box().read());'],
  [
    'constructor before fields',
    'class Box{constructor(){this.other=2}value=7;read=()=>this.value}const box=new Box();console.log(box.read(),box.other);',
  ],
  [
    'constructor body and field arrows',
    'class Box{value=7;read=()=>this.value;constructor(){this.body=()=>this.value}}const box=new Box();console.log(box.read(),box.body());',
  ],
  [
    'constructor collision',
    'class Box{value=7;read=()=>this.value;constructor(_this){this.other=_this}}const box=new Box(11);console.log(box.read(),box.other);',
  ],
  [
    'shared nested field arrows',
    'class Box{value=7;first=()=>this.value;second=()=>()=>this.value+1}const box=new Box();console.log(box.first(),box.second()());',
  ],
  [
    'implicit derived',
    'class Parent{constructor(){this.base=1}}class Box extends Parent{value=7;read=()=>[this.value,this.base]}console.log(JSON.stringify(new Box().read()));',
  ],
  [
    'explicit derived',
    'class Parent{constructor(){this.base=1}}class Box extends Parent{value=7;read=()=>this.value;constructor(){super();this.extra=2}}const box=new Box();console.log(box.read(),box.extra);',
  ],
  [
    'replacement super object',
    'class Parent{constructor(){return{value:4}}}class Box extends Parent{value=7;read=()=>this.value}const box=new Box();console.log(box.read(),box.value);',
  ],
  [
    'outer frame restoration',
    'function build(){const outer=()=>this;class Box{value=7;read=()=>this.value}return[outer().tag,new Box().read()]}console.log(JSON.stringify(build.call({tag:"outer"})));',
  ],
  [
    'field newtarget',
    'class Box{value=7;read=()=>[this.value,new.target];constructor(){this.actual=new.target}}const box=new Box();console.log(JSON.stringify([box.read(),box.actual===Box]));',
  ],
  [
    'async field arrow',
    'class Box{value=7;read=async()=>this.value}new Box().read().then(value=>console.log(value));',
  ],
  [
    'nested ordinary function boundary',
    'class Box{read=(function(){return()=>this.value}).call({value:9})}console.log(new Box().read());',
  ],
  [
    'constructor first shared storage',
    'class Box{constructor(){this.body=()=>this.value}value=7;read=()=>this.value}const box=new Box();console.log(box.read(),box.body());',
  ],
] as const;
afterAll(() => close());
for (const [name, source] of cases)
  for (const rnVersion of ['0.80', '0.84'])
    for (const mode of ['plain', 'identifiers', 'full'] as const)
      for (const surface of ['CLI', 'buildSync', 'build'] as const) {
        test(`native field captures ${surface}/${name}/RN${rnVersion}/${mode}`, async () => {
          const fixture = await createFixture({ 'input.cjs': source });
          try {
            const input = join(fixture.dir, 'input.cjs');
            const output = join(fixture.dir, 'output.cjs');
            const native = spawnSync('node', [input], { encoding: 'utf8' });
            expect(native.status, native.stderr).toBe(0);
            if (surface === 'CLI') {
              const compiled = spawnSync(
                process.env.ZNTC_NATIVE_FIELD_CAPTURE_CLI ?? ZNTC_BIN,
                [
                  input,
                  '--bundle',
                  '--platform=react-native',
                  `--rn-version=${rnVersion}`,
                  '--format=cjs',
                  '--use-define-for-class-fields=false',
                  ...(mode === 'full'
                    ? ['--minify']
                    : mode === 'identifiers'
                      ? ['--minify-identifiers']
                      : []),
                  '-o',
                  output,
                ],
                { encoding: 'utf8', env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
              );
              expect(compiled.status, compiled.stderr).toBe(0);
              expect(compiled.stderr).not.toContain('clean=0');
            } else {
              const options = {
                entryPoints: [input],
                outfile: output,
                write: false,
                platform: 'react-native' as const,
                rnVersion,
                format: 'cjs' as const,
                useDefineForClassFields: false,
                minifyIdentifiers: mode !== 'plain',
                minifySyntax: mode === 'full',
                minifyWhitespace: mode === 'full',
              };
              const result = surface === 'buildSync' ? buildSync(options) : await build(options);
              expect(result.errors ?? []).toHaveLength(0);
              expect(result.outputFiles).toHaveLength(1);
              await writeFile(output, result.outputFiles[0]!.text);
            }
            const actual = spawnSync('node', [output], { encoding: 'utf8' });
            expect(actual.status, actual.stderr).toBe(0);
            expect(actual.stdout).toBe(native.stdout);
          } finally {
            await fixture.cleanup();
          }
        });
      }
