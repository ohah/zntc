import { afterAll, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import {
  build,
  buildSync,
  close,
  init,
  transpile,
  type BuildOptions,
} from '../../../packages/core/index.ts';
import { createFixture, ZNTC_BIN } from './helpers';

// A new explicit target limitation, not a native-runtime success. The source
// oracle throws ReferenceError without leaking a sloppy global assignment.
const source =
  "delete globalThis.__heritageLeak;globalThis.Base=class{};try{class Clazz extends eval('(__heritageLeak=1,globalThis.Base)'){};console.log('unexpected')}catch(error){console.log(JSON.stringify([error.name,typeof globalThis.__heritageLeak]))}";
if (process.env.ZNTC_HERITAGE_NAPI) init(process.env.ZNTC_HERITAGE_NAPI);
afterAll(() => close());

for (const minify of [false, true]) {
  test(`ZNTC1512 transpile explicit ES5 rejection minify=${minify}`, () => {
    if (!process.env.ZNTC_HERITAGE_NAPI) init();
    expect(() => transpile(source, { target: 'es5', minify, filename: 'heritage.cjs' })).toThrow(
      'ZNTC1512',
    );
  });
  for (const api of ['sync', 'async'] as const)
    for (const existing of [false, true])
      test(`ZNTC1512 ${api} atomic write:true minify=${minify} existing=${existing}`, async () => {
        const { dir, cleanup } = await createFixture({ 'entry.cjs': source });
        try {
          if (!process.env.ZNTC_HERITAGE_NAPI) init();
          const outfile = join(dir, 'output.cjs');
          const sentinel = 'heritage publication sentinel\n';
          if (existing) writeFileSync(outfile, sentinel);
          const options: BuildOptions = {
            entryPoints: [join(dir, 'entry.cjs')],
            outfile,
            platform: 'node',
            format: 'cjs',
            target: 'es5',
            minify,
            write: true,
          };
          let failure: unknown;
          try {
            if (api === 'sync') buildSync(options);
            else await build(options);
          } catch (error) {
            failure = error;
          }
          expect(String(failure)).toContain('ZNTC1512');
          expect(existsSync(outfile)).toBe(existing);
          if (existing) expect(readFileSync(outfile, 'utf8')).toBe(sentinel);
          expect(existsSync(`${outfile}.map`)).toBe(false);
        } finally {
          await cleanup();
        }
      });
}

const controls = [
  {
    name: 'indirect',
    source:
      "globalThis.Base=class{};class Cell extends(0,eval)('globalThis.Base'){};console.log(new Cell() instanceof globalThis.Base)",
  },
  {
    name: 'optional',
    source:
      "globalThis.Base=class{};class Cell extends eval?.('globalThis.Base'){};console.log(new Cell() instanceof globalThis.Base)",
  },
  {
    name: 'nested-function',
    source:
      "globalThis.Base=class{};class Cell extends(function(){return eval('globalThis.Base')})(){};console.log(new Cell() instanceof globalThis.Base)",
  },
  { name: 'strict-parent', source: "'use strict';" + source },
  { name: 'module-parent', source: 'export {};' + source },
] as const;
for (const api of ['sync', 'async'] as const)
  for (const target of ['es5', 'esnext', 'chrome49'] as const)
    for (const control of controls)
      test(`heritage eval ${control.name} healthy ${api} target=${target}`, async () => {
        const entryName = control.name === 'module-parent' ? 'entry.mjs' : 'entry.cjs';
        const { dir, cleanup } = await createFixture({ [entryName]: control.source });
        try {
          if (!process.env.ZNTC_HERITAGE_NAPI) init();
          const native = spawnSync('node', [join(dir, entryName)], { encoding: 'utf8' });
          expect(native.status).toBe(0);
          const options: BuildOptions = {
            entryPoints: [join(dir, entryName)],
            platform: 'node',
            format: control.name === 'module-parent' ? 'esm' : 'cjs',
            target,
            write: false,
          };
          const result = api === 'sync' ? buildSync(options) : await build(options);
          expect(result.errors).toEqual([]);
          expect(result.outputFiles.length).toBeGreaterThan(0);
          const output = join(dir, control.name === 'module-parent' ? 'actual.mjs' : 'actual.cjs');
          writeFileSync(output, result.outputFiles[0].text);
          const actual = spawnSync('node', [output], { encoding: 'utf8' });
          expect(actual.status).toBe(native.status);
          expect(actual.stdout).toBe(native.stdout);
          expect(actual.stderr).toBe(native.stderr);
        } finally {
          await cleanup();
        }
      });

for (const minify of [false, true])
  for (const existing of [false, true])
    test(`ZNTC1512 actual CLI atomic output minify=${minify} existing=${existing}`, async () => {
      const { dir, cleanup } = await createFixture({ 'entry.cjs': source });
      try {
        const outfile = join(dir, 'output.cjs');
        const sentinel = 'CLI heritage publication sentinel\n';
        if (existing) writeFileSync(outfile, sentinel);
        const args = [
          '--bundle',
          join(dir, 'entry.cjs'),
          '--format=cjs',
          '--platform=node',
          '--target=es5',
          '-o',
          outfile,
        ];
        if (minify) args.push('--minify');
        const result = spawnSync(process.env.ZNTC_HERITAGE_CLI ?? ZNTC_BIN, args, {
          cwd: dir,
          encoding: 'utf8',
        });
        expect(result.status).toBe(1);
        expect(result.stderr).toContain('ZNTC1512');
        expect(result.stdout).toBe('');
        expect(existsSync(outfile)).toBe(existing);
        if (existing) expect(readFileSync(outfile, 'utf8')).toBe(sentinel);
      } finally {
        await cleanup();
      }
    });
