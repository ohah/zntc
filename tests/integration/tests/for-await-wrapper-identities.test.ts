import { afterAll, expect, test } from 'bun:test';
import { buildSync, close, transpile } from '../../../packages/core/index';
import { spawnSync } from 'node:child_process';
import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';
const cases = [
  ['exhaustion', 'for await(const value of make([1,2],{})){events.push(value);}'],
  ['break closes', 'for await(const value of make([1,2],{})){events.push(value);break;}'],
  ['return closes', 'for await(const value of make([1,2],{})){return value;}'],
  ['body throw closes', 'for await(const value of make([1,2],{})){throw Error("body");}'],
  [
    'first next rejects',
    'for await(const value of make([1,2],{nextThrow:true})){events.push(value);}',
  ],
  [
    'return getter throws',
    'for await(const value of make([1,2],{getThrow:true})){events.push(value);break;}',
  ],
  [
    'close rejects',
    'for await(const value of make([1,2],{closeThrow:true})){events.push(value);break;}',
  ],
  [
    'nested close scopes',
    'for await(const value of make([1,2],{})){for await(const inner of make([3,4],{})){events.push(value,inner);break;}}',
  ],
  [
    'shadow and closures',
    'const reads=[];const _err=9,_step=8;for await(const [value=42] of make([[1],[]],{})){const copy=value;reads.push(()=>copy);events.push(_err,_step);}events.push(reads.map(read=>read()).join(":"));',
  ],
  [
    'labeled continue closes inner',
    'outer:for await(const value of make([1,2],{})){for await(const inner of make([3,4],{})){events.push(value,inner);continue outer;}}',
  ],
] as const;
function sourceFor(body: string, generator: boolean): string {
  return `const events=[];
function make(values,flags){let index=0;return {
 [Symbol.asyncIterator](){events.push("iterator");return this;},
 async next(){events.push("next:"+index);if(flags.nextThrow)throw Error("next");return index<values.length?{value:values[index++],done:false}:{done:true};},
 get return(){events.push("get-return");if(flags.getThrow)throw Error("get");return async function(){events.push("close");if(flags.closeThrow)throw Error("close");return {done:true};};}
};}
async function${generator ? '*' : ''} run(){${body}${generator ? ';yield "end";' : ''}}
async function finish(){try{${generator ? 'const iterator=run();let result;do{result=await iterator.next();events.push(["step",result.value,result.done]);}while(!result.done);' : 'events.push(["return",await run()]);'}}catch(error){events.push("error:"+error.message);}console.log(JSON.stringify(events));}finish();`;
}
afterAll(() => close());
const modes = [
  ...(['es5', 'es2015', 'es2017', 'es2018', 'esnext'] as const).flatMap((target) =>
    [false, true].flatMap((bundle) =>
      [false, true].map((minify) => ({ surface: 'CLI' as const, target, bundle, minify })),
    ),
  ),
  ...(['es5', 'es2022'] as const).flatMap((target) =>
    (['transpile', 'buildSync'] as const).flatMap((surface) =>
      [false, true].map((minify) => ({ surface, target, bundle: false, minify })),
    ),
  ),
];
for (const [name, body] of cases)
  for (const generator of [false, true])
    for (const mode of modes) {
      test(`for-await cleanup ${mode.surface}/${name}/${generator ? 'generator' : 'function'}/${mode.target}/${mode.bundle}/${mode.minify}`, async () => {
        const source = sourceFor(body, generator);
        const fixture = await createFixture({ 'input.cjs': source });
        try {
          const input = join(fixture.dir, 'input.cjs'),
            output = join(fixture.dir, 'output.cjs');
          const native = spawnSync('node', [input], { encoding: 'utf8' });
          expect(native.status, native.stderr).toBe(0);
          const options = {
            target: mode.target,
            format: 'cjs' as const,
            minifyIdentifiers: mode.minify,
            minifySyntax: mode.minify,
            minifyWhitespace: mode.minify,
          };
          if (mode.surface === 'CLI') {
            const result = spawnSync(
              process.env.FOR_AWAIT_SCOPE_TEST_BIN ?? ZNTC_BIN,
              [
                input,
                `--target=${mode.target}`,
                '--format=cjs',
                ...(mode.bundle ? ['--bundle', '--platform=node'] : []),
                ...(mode.minify ? ['--minify'] : []),
                '-o',
                output,
              ],
              { encoding: 'utf8', env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
            );
            expect(result.status, result.stderr).toBe(0);
            expect(result.stderr).not.toContain('clean=0');
          } else if (mode.surface === 'transpile') {
            const result = transpile(source, { ...options, filename: input });
            expect(result.errors ?? []).toHaveLength(0);
            await writeFile(output, result.code);
          } else {
            const result = buildSync({
              ...options,
              entryPoints: [input],
              outfile: output,
              platform: 'node',
              write: false,
            });
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
