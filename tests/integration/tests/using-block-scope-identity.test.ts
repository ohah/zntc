import { afterAll, afterEach, describe, expect, test } from 'bun:test';
import { writeFile } from 'node:fs/promises';
import { buildSync, close, transpile } from '../../../packages/core/index';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';
const resource = '({[Symbol.dispose](){events.push("dispose")}})';
const cases = [
  [
    'program',
    `using resource=${resource};const value=42;const read=()=>value;events.push(read());`,
  ],
  [
    'function',
    `function run(){using resource=${resource};const value=42;const read=()=>value;return read();}events.push(run());`,
  ],
  [
    'nested block',
    `let value=7;{using resource=${resource};const value=42;events.push((()=>value)());}events.push(value);`,
  ],
  [
    'await using',
    'async function run(){await using resource={[Symbol.asyncDispose](){events.push("dispose")}};const value=42;return(()=>value)();}run().then(value=>events.push(value));',
  ],
  [
    'generator',
    `function* run(){using resource=${resource};const value=42;yield(()=>value)();}const iterator=run();events.push(iterator.next().value);iterator.return();`,
  ],
  [
    'try finally',
    `function run(){try{using resource=${resource};let value=42;return()=>value;}finally{events.push("finally");}}events.push(run()());`,
  ],
  [
    'catch binding',
    `try{throw 42;}catch(value){using resource=${resource};const read=()=>value;events.push(read());}`,
  ],
  [
    'class method',
    `class Box{value=42;run(){using resource=${resource};return(()=>this.value)();}}events.push(new Box().run());`,
  ],
  [
    'non-simple arrow parameter',
    `const run=(value=42)=>{using resource=${resource};return(()=>value)();};events.push(run());`,
  ],
  [
    'per-iteration closure',
    `const reads=[];for(let index=0;index<2;index++){using resource=${resource};const value=index+41;reads.push(()=>value);}events.push(reads.map(read=>read()).join(":"));`,
  ],
] as const;
describe('using block producer scopes (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });
  for (const [name, body] of cases)
    for (const target of ['es2022', 'es2020', 'es2017', 'es2015', 'es5', 'esnext'])
      for (const bundle of [false, true])
        for (const minify of [false, true]) {
          test(`${name}: ${target}/${bundle ? 'bundle' : 'standalone'}/${minify ? 'min' : 'plain'}`, async () => {
            const fixture = await createFixture({
              'input.cjs': `const events=[];${body}\nsetTimeout(()=>console.log(JSON.stringify(events)),0);`,
            });
            cleanup = fixture.cleanup;
            const input = join(fixture.dir, 'input.cjs');
            const output = join(fixture.dir, 'output.cjs');
            const native = spawnSync('node', [input], { encoding: 'utf8' });
            expect(native.status, native.stderr).toBe(0);
            const built = spawnSync(
              ZNTC_BIN,
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

describe('using block scopes through the native API', () => {
  for (const [name, body] of cases) {
    for (const target of ['es2022', 'es5'] as const) {
      for (const surface of ['transpile', 'buildSync'] as const) {
        for (const minify of [false, true]) {
          test(`${name}: ${target}/${surface}/${minify ? 'min' : 'plain'}`, async () => {
            const source = `const events=[];${body}\nsetTimeout(()=>console.log(JSON.stringify(events)),0);`;
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
      }
    }
  }
});
