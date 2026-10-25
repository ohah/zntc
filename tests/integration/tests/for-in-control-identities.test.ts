import { afterAll, expect, test } from 'bun:test';
import { buildSync, close, transpile } from '../../../packages/core/index';
import { spawnSync } from 'node:child_process';
import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';
const cases = [
  ['const keys', 'for(const key in source){yield key;}'],
  ['let closures', 'for(let key in source){reads.push(()=>key);yield key;}'],
  ['var storage', 'for(var key in source){yield key;}events.push(key);'],
  ['assignment head', 'let key;for(key in source){yield key;}events.push(key);'],
  [
    'body cell closures',
    'for(const key in source){const copy=key;reads.push(()=>copy);yield copy;}',
  ],
  ['single body', 'for(const key in source)yield key;'],
  [
    'inherited keys and Object shadow',
    'const Object=null;for(let key in source){yield key;}events.push(Object);',
  ],
  ['body shadow', 'for(const key in source){const key="inner";yield key;}'],
  [
    'labeled continue',
    'outer:for(let key in source){for(const value of [1,2]){if(value===1)continue outer;yield key;}}',
  ],
  [
    'RHS and shorthand closure',
    'const factor=42;let calls=0;function get(){events.push(++calls);return source;}for(let key in get()){const read=()=>({key,factor});reads.push(read);yield read();}',
  ],
] as const;
function sourceFor(body: string, generator: boolean): string {
  return `const events=[],reads=[];const source={alpha:1,beta:2};Object.setPrototypeOf(source,{inherited:3});
${generator ? 'async ' : ''}function* run(source){${body};return "end";}
async function finish(){try{const iterator=run(source);let result;do{result=await iterator.next();events.push(["step",result.value,result.done]);}while(!result.done);events.push(["reads",reads.map(read=>read())]);}catch(error){events.push("error:"+error.message);}console.log(JSON.stringify(events));}finish();`;
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
      test(`for-in control ${mode.surface}/${name}/${generator ? 'async-generator' : 'generator'}/${mode.target}/${mode.bundle}/${mode.minify}`, async () => {
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
              process.env.FOR_IN_SCOPE_TEST_BIN ?? ZNTC_BIN,
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
