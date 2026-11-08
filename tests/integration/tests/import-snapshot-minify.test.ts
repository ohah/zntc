import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { buildSync, close, init } from '../../../packages/core/index';
import { createFixture, ZNTC_BIN } from './helpers';

const cliOnly = process.env.ZNTC_TEST_CLI_ONLY === '1';
const surfaces = cliOnly ? (['cli'] as const) : (['cli', 'napi'] as const);
const modes = ['plain', 'syntax', 'identifiers', 'whitespace', 'full'] as const;
const lib = 'export let value=1; export default value; export function advance(){value++;}';
const cases = [
  {
    name: 'named snapshot',
    lib,
    main: 'import initial,{value,advance}from "./lib.mjs";advance();const first=value;advance();console.log(JSON.stringify([initial,first,value]));',
    expected: '[1,2,3]\n',
  },
  {
    name: 'renamed snapshot',
    lib,
    main: 'import{value as current,advance as step}from "./lib.mjs";step();const saved=current;step();console.log(JSON.stringify([saved,current]));',
    expected: '[2,3]\n',
  },
  {
    name: 'compound snapshot',
    lib,
    main: 'import{value,advance}from "./lib.mjs";advance();const first=value+10;advance();console.log(JSON.stringify([first,value]));',
    expected: '[12,3]\n',
  },
  {
    name: 'alias chain',
    lib,
    main: 'import{value,advance}from "./lib.mjs";advance();const first=value;const second=first;advance();console.log(JSON.stringify([second,value]));',
    expected: '[2,3]\n',
  },
  {
    name: 'barrel reexport',
    lib,
    barrel: 'export{value,advance}from "./lib.mjs";',
    main: 'import{value,advance}from "./barrel.mjs";advance();const first=value;advance();console.log(JSON.stringify([first,value]));',
    expected: '[2,3]\n',
  },
  {
    name: 'live default export',
    lib: 'let value=1;export{value as default};export function advance(){value++;}',
    main: 'import value,{advance}from "./lib.mjs";advance();const first=value;advance();console.log(JSON.stringify([first,value]));',
    expected: '[2,3]\n',
  },
  {
    name: 'namespace snapshot',
    lib,
    main: 'import * as ns from "./lib.mjs";ns.advance();const first=ns.value;ns.advance();console.log(JSON.stringify([first,ns.value]));',
    expected: '[2,3]\n',
  },
  {
    name: 'local immutable alias control',
    lib: 'export const value=2;',
    main: 'function local(n){const first=n;const second=first;return second+1;}console.log(local(2));',
    expected: '3\n',
  },
];
beforeAll(() => {
  if (!cliOnly) init(process.env.ZNTC_NAPI_PATH);
});
afterAll(() => close());
describe('import snapshots keep acquisition time (#6958)', () => {
  for (const surface of surfaces)
    for (const mode of modes)
      for (const item of cases) {
        test(`${surface} ${mode}: ${item.name}`, async () => {
          const files: Record<string, string> = { 'lib.mjs': item.lib, 'main.mjs': item.main };
          if (item.barrel) files['barrel.mjs'] = item.barrel;
          const fixture = await createFixture(files);
          try {
            const entry = join(fixture.dir, 'main.mjs'),
              outfile = join(fixture.dir, 'dist', 'entry.mjs');
            const run = (path: string) =>
              spawnSync(process.env.ZNTC_NODE_BIN ?? 'node', [path], {
                cwd: fixture.dir,
                encoding: 'utf8',
              });
            const native = run(entry);
            expect(native.error).toBeUndefined();
            expect(native.status, native.stderr).toBe(0);
            expect(native.stdout).toBe(item.expected);
            if (surface === 'cli') {
              const flags =
                mode === 'full' ? ['--minify'] : mode === 'plain' ? [] : [`--minify-${mode}`];
              const result = spawnSync(
                process.env.ZNTC_BIN ?? ZNTC_BIN,
                [
                  '--bundle',
                  entry,
                  '--format=esm',
                  '--platform=node',
                  '--target=esnext',
                  '-o',
                  outfile,
                  ...flags,
                ],
                { cwd: fixture.dir, encoding: 'utf8' },
              );
              expect(result.error).toBeUndefined();
              expect(result.status, result.stderr).toBe(0);
            } else {
              const result = buildSync({
                entryPoints: [entry],
                rootDir: fixture.dir,
                outfile,
                target: 'esnext',
                platform: 'node',
                format: 'esm',
                write: true,
                minifySyntax: mode === 'syntax' || mode === 'full',
                minifyIdentifiers: mode === 'identifiers' || mode === 'full',
                minifyWhitespace: mode === 'whitespace' || mode === 'full',
              });
              expect(result.errors, JSON.stringify(result.errors)).toHaveLength(0);
            }
            const actual = run(outfile);
            expect(actual.error).toBeUndefined();
            expect(actual.status, actual.stderr).toBe(native.status);
            expect(actual.stdout).toBe(native.stdout);
            expect(actual.stderr).toBe(native.stderr);
          } finally {
            await fixture.cleanup();
          }
        });
      }
});
