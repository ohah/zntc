import { afterAll, afterEach, describe, expect, test } from 'bun:test';
import { buildSync, close, transpile } from '../../../packages/core/index';
import { writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

const cases = [
  [
    'generator header names and shorthand keys',
    'const reads=[];function* nested(){for (let index=0;index<2;index++){const value=index+41;yield 0;reads.push(()=>({index,value}));}}for(const ignored of nested()){}events.push(reads.map(read=>JSON.stringify(read())).join(":"));',
  ],
  [
    'body cell closures',
    'const reads=[];for(const value of [20,21]){const copy=value*2;reads.push(()=>copy);}events.push(reads.map(read=>read()).join(":"));',
  ],
  ['const reads', 'for(const value of [41,42]){events.push(value);}'],
  [
    'let closures',
    'const reads=[];for(let value of [41,42]){reads.push(()=>value);}events.push(reads.map(read=>read()).join(":"));',
  ],
  ['var storage', 'for(var value of [41,42]){events.push(value);}events.push(value);'],
  ['assignment head', 'let value;for(value of [41,42]){events.push(value);}events.push(value);'],
  ['object binding', 'for(const {value} of [{value:41},{value:42}]){events.push(value);}'],
  ['array binding', 'for(const [value] of [[41],[42]]){events.push(value);}'],
  ['single statement', 'for(const value of [41,42])events.push(value);'],
  [
    'nested shadows',
    'for(const value of [41,42]){let copy=value;{let value=7;events.push(value,copy);}}',
  ],
  ['head/body shadow', 'for(const value of [41,42]){const value=7;events.push(value);}'],
  [
    'default closure and continue',
    'const reads=[];for(const [value,read=()=>value] of [[41],[42]]){reads.push(read);if(value===41)continue;events.push(read());}events.push(reads.map(read=>read()).join(":"));',
  ],
] as const;

describe('loop body producer identities (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });
  for (const [name, body] of cases)
    for (const asynchronous of [false, true])
      for (const target of ['es5', 'es2015', 'es2017', 'es2018', 'esnext'])
        for (const bundle of [false, true])
          for (const minify of [false, true]) {
            test(`${name}/${asynchronous ? 'for-await' : 'for-of'}/${target}/${bundle ? 'bundle' : 'single'}/${minify ? 'min' : 'plain'}`, async () => {
              const source = `const events=[];async function run(){${asynchronous ? body.replaceAll('for(', 'for await(') : body}}run().then(()=>console.log(JSON.stringify(events)),error=>{console.error(error);process.exitCode=1;});`;
              const fixture = await createFixture({ 'input.cjs': source });
              cleanup = fixture.cleanup;
              const input = join(fixture.dir, 'input.cjs');
              const output = join(fixture.dir, 'output.cjs');
              const native = spawnSync('node', [input], { encoding: 'utf8' });
              expect(native.status, native.stderr).toBe(0);
              const built = spawnSync(
                process.env.LOOP_SCOPE_TEST_BIN ?? ZNTC_BIN,
                [
                  input,
                  `--target=${target}`,
                  '--format=cjs',
                  ...(bundle ? ['--bundle', '--platform=node'] : []),
                  ...(minify ? ['--minify'] : []),
                  '-o',
                  output,
                ],
                { encoding: 'utf8', env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
              );
              expect(built.status, built.stderr).toBe(0);
              expect(built.stderr).not.toContain('clean=0');
              const actual = spawnSync('node', [output], { encoding: 'utf8' });
              expect(actual.status, actual.stderr).toBe(0);
              expect(actual.stdout).toBe(native.stdout);
            });
          }
});

afterAll(() => close());
describe('loop body scopes through native API', () => {
  for (const [name, body] of cases)
    for (const asynchronous of [false, true])
      for (const target of ['es5', 'es2022'] as const)
        for (const surface of ['transpile', 'buildSync'] as const)
          for (const minify of [false, true]) {
            test(`${name}/${asynchronous ? 'for-await' : 'for-of'}/${target}/${surface}/${minify ? 'min' : 'plain'}`, async () => {
              const source = `const events=[];async function run(){${asynchronous ? body.replaceAll('for(', 'for await(') : body}}run().then(()=>console.log(JSON.stringify(events)),error=>{console.error(error);process.exitCode=1;});`;
              const fixture = await createFixture({ 'input.cjs': source });
              try {
                const input = join(fixture.dir, 'input.cjs');
                const output = join(fixture.dir, 'output.cjs');
                const native = spawnSync('node', [input], { encoding: 'utf8' });
                expect(native.status, native.stderr).toBe(0);
                const options = {
                  target,
                  format: 'cjs' as const,
                  minifyIdentifiers: minify,
                  minifySyntax: minify,
                  minifyWhitespace: minify,
                };
                let code: string;
                if (surface === 'transpile') {
                  const result = transpile(source, { ...options, filename: input });
                  expect(result.errors ?? []).toHaveLength(0);
                  code = result.code;
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
                  code = result.outputFiles[0]!.text;
                }
                await writeFile(output, code);
                const actual = spawnSync('node', [output], { encoding: 'utf8' });
                expect(actual.status, actual.stderr).toBe(0);
                expect(actual.stdout).toBe(native.stdout);
              } finally {
                await fixture.cleanup();
              }
            });
          }
});
