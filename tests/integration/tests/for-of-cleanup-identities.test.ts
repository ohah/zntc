import { afterAll, expect, test } from 'bun:test';
import { buildSync, close, transpile } from '../../../packages/core/index';
import { spawnSync } from 'node:child_process';
import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';
const cases = [
  ['break closes', 'for(const value of source){events.push(value);break;}'],
  [
    'body throw',
    'try{for(const value of source){throw new Error("body");}}catch(error){events.push(error.message);}',
  ],
  ['return closes', 'for(const value of source){return value;}'],
  ['normal exhaustion', 'for(const value of source){events.push(value);}'],
  ['closures', 'for(let value of source){reads.push(()=>value);}'],
  ['destructuring', 'for(const [value=42] of source){events.push(value);break;}'],
  [
    'label continue',
    'outer:for(const value of source){for(const inner of [1,2]){if(inner===1)continue outer;}}',
  ],
  [
    'nested cleanup',
    'for(const value of source){for(const inner of source){events.push(inner);break;}break;}',
  ],
  [
    'shadowed temps',
    'const _err=8,_step=9;for(const value of source){{const value=3;events.push(value,_err,_step);}break;}',
  ],
  [
    'close error preserves body',
    'try{for(const value of source){throw new Error("body");}}catch(error){events.push(error.message);}',
  ],
] as const;
function sourceFor(body: string, kind: string, name: string): string {
  return `const events=[],reads=[];const source={[Symbol.iterator](){let index=0;return {next(){events.push("next:"+index);return index++<2?{value:${name === 'destructuring' ? '[index]' : 'index'},done:false}:{done:true};},return(){events.push("close");${name === 'close error preserves body' ? 'throw new Error("close");' : 'return {done:true};'}}};}};
${kind === 'async-generator' ? 'async ' : ''}function${kind === 'ordinary' ? '' : '*'} run(source){${body};return "end";}
async function finish(){try{const result=run(source);if(result&&result.next){let step;do{step=await result.next();events.push(["step",step.value,step.done]);}while(!step.done);}else events.push(["return",result]);events.push(["reads",reads.map(read=>read())]);}catch(error){events.push("error:"+error.message);}console.log(JSON.stringify(events));}finish();`;
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
  for (const kind of ['ordinary', 'generator', 'async-generator'])
    for (const mode of modes) {
      test(`for-of cleanup ${mode.surface}/${name}/${kind}/${mode.target}/${mode.bundle}/${mode.minify}`, async () => {
        const source = sourceFor(body, kind, name);
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
              process.env.FOR_OF_SCOPE_TEST_BIN ?? ZNTC_BIN,
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
