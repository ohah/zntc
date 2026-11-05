import { afterAll, expect, test } from 'bun:test';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { build, buildSync, close, init, type BuildOptions } from '../../../packages/core/index.ts';
import { createFixture } from './helpers';

const cases = [
  { code: 'ZNTC1509', target: 'es5', source: "for(let index=0;index<2;index++){eval('index=9')}" },
  {
    code: 'ZNTC1510',
    target: 'chrome49',
    source: 'function* run(){for(var i=0;i<2;i++){class Cell{}yield 0;use(()=>Cell)}}run();',
  },
  {
    code: 'ZNTC1511',
    target: 'chrome49',
    source:
      'function* run(){for(let i=0;i<2;i++){use(()=>i);for(let i=4;i<6;i++){yield 0;use(()=>i)}}}run();',
  },
] as const;

if (process.env.ZNTC_LOOP_CAPTURE_NAPI) init(process.env.ZNTC_LOOP_CAPTURE_NAPI);
afterAll(() => close());
for (const api of ['sync', 'async'] as const)
  for (const input of cases)
    for (const minify of [false, true])
      for (const existing of [false, true])
        test(`${input.code} ${api} write:true cannot publish partial output minify=${minify} existing=${existing}`, async () => {
          const { dir, cleanup } = await createFixture({ 'entry.cjs': input.source });
          try {
            if (!process.env.ZNTC_LOOP_CAPTURE_NAPI) init();
            const outfile = join(dir, 'output.cjs');
            const sentinel = 'untouched output sentinel\n';
            if (existing) writeFileSync(outfile, sentinel);
            const options: BuildOptions = {
              entryPoints: [join(dir, 'entry.cjs')],
              outfile,
              target: input.target,
              format: 'cjs',
              write: true,
              minify,
            };
            let failure: unknown;
            try {
              if (api === 'sync') buildSync(options);
              else await build(options);
            } catch (error) {
              failure = error;
            }
            expect(String(failure)).toContain(input.code);
            expect(existsSync(outfile)).toBe(existing);
            if (existing) expect(readFileSync(outfile, 'utf8')).toBe(sentinel);
            expect(existsSync(`${outfile}.map`)).toBe(false);
          } finally {
            await cleanup();
          }
        });
