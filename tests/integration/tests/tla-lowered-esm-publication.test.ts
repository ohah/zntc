import { afterAll, expect, test } from 'bun:test';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { build, buildSync, close, init, type BuildOptions } from '../../../packages/core/index.ts';
import { createFixture } from './helpers';

if (process.env.ZNTC_LOWERED_TLA_NAPI) init(process.env.ZNTC_LOWERED_TLA_NAPI);
afterAll(() => close());
for (const api of ['sync', 'async'] as const)
  for (const preserveModules of [false, true])
    for (const existing of [false, true])
      test(`lowered ESM publication ${api} preserve=${preserveModules} existing=${existing}`, async () => {
        const { dir, cleanup } = await createFixture({
          'entry.mjs':
            "import {combined} from './consumer.mjs';export {combined};export function load(){return import('./lazy.mjs')}",
          'consumer.mjs': "import {value} from './slow.mjs';export const combined=value;",
          'slow.mjs': 'export let value=0;await Promise.resolve();value=42;',
          'lazy.mjs': "export {combined} from './consumer.mjs';",
        });
        try {
          if (!process.env.ZNTC_LOWERED_TLA_NAPI) init();
          const outdir = join(dir, 'dist');
          const outfile = join(outdir, 'entry.js');
          const sentinel = 'keep prior output\n';
          if (existing) {
            mkdirSync(outdir);
            writeFileSync(outfile, sentinel);
          }
          const options: BuildOptions = {
            entryPoints: [join(dir, 'entry.mjs')],
            outdir,
            format: 'esm',
            target: 'es5',
            splitting: true,
            preserveModules,
            write: true,
          };
          const result = api === 'sync' ? buildSync(options) : await build(options);
          expect(result.hasErrors).toBe(true);
          expect(result.errors.some((error) => error.code === 'top_level_await_target')).toBe(true);
          expect(result.outputFiles).toHaveLength(0);
          expect(existsSync(outfile)).toBe(existing);
          if (existing) expect(readFileSync(outfile, 'utf8')).toBe(sentinel);
          expect(existsSync(join(outdir, 'consumer.js'))).toBe(false);
          expect(existsSync(join(outdir, 'slow.js'))).toBe(false);
        } finally {
          await cleanup();
        }
      });
