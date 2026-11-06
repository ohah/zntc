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

for (const api of ['sync', 'async'] as const)
  for (const existing of [false, true])
    test(`parse_error ${api} write:true preserves filesystem existing=${existing}`, async () => {
      const { dir, cleanup } = await createFixture({
        'entry.cjs': "new Worker(new URL('./worker.cjs', import.meta.url));",
        'worker.cjs': 'console.log(42);',
      });
      try {
        if (!process.env.ZNTC_LOOP_CAPTURE_NAPI) init();
        const outfile = join(dir, 'output.cjs');
        const sentinel = 'untouched parse-error sentinel\n';
        if (existing) writeFileSync(outfile, sentinel);
        const options: BuildOptions = {
          entryPoints: [join(dir, 'entry.cjs')],
          outfile,
          format: 'cjs',
          write: true,
        };
        // Generic native diagnostic results remain results, with the actual
        // parser diagnostic intact. They must not enter filesystem publication.
        const result = api === 'sync' ? buildSync(options) : await build(options);
        expect(result.errors.some((diagnostic) => diagnostic.code === 'parse_error')).toBe(true);
        expect(existsSync(outfile)).toBe(existing);
        if (existing) expect(readFileSync(outfile, 'utf8')).toBe(sentinel);
        expect(existsSync(`${outfile}.map`)).toBe(false);
      } finally {
        await cleanup();
      }
    });

for (const api of ['sync', 'async'] as const)
  for (const logLevel of ['warning', 'silent'] as const)
    for (const failed of [false, true])
      for (const existing of [false, true])
        test(`unfiltered publication status ${api} ${logLevel} failed=${failed} existing=${existing}`, async () => {
          const { dir, cleanup } = await createFixture({
            'entry.cjs': failed
              ? "new Worker(new URL('./worker.cjs', import.meta.url));"
              : 'console.log(42);',
            'worker.cjs': 'console.log(42);',
          });
          try {
            if (!process.env.ZNTC_LOOP_CAPTURE_NAPI) init();
            const outfile = join(dir, 'output.cjs');
            const sentinel = 'unfiltered publication sentinel\n';
            if (existing) writeFileSync(outfile, sentinel);
            const options: BuildOptions = {
              entryPoints: [join(dir, 'entry.cjs')],
              outfile,
              format: 'cjs',
              logLevel,
              write: true,
            };
            const result = api === 'sync' ? buildSync(options) : await build(options);
            expect(result.hasErrors).toBe(failed);
            expect(result.outputFiles.length).toBeGreaterThan(0);
            if (logLevel === 'silent') {
              expect(result.errors).toEqual([]);
              expect(result.warnings).toEqual([]);
            } else if (failed) {
              expect(result.errors.some((diagnostic) => diagnostic.code === 'parse_error')).toBe(
                true,
              );
            } else {
              expect(result.errors).toEqual([]);
            }
            if (failed) {
              expect(existsSync(outfile)).toBe(existing);
              if (existing) expect(readFileSync(outfile, 'utf8')).toBe(sentinel);
            } else {
              expect(existsSync(outfile)).toBe(true);
              const written = readFileSync(outfile, 'utf8');
              expect(written).not.toBe(sentinel);
              expect(written).toContain('42');
            }
          } finally {
            await cleanup();
          }
        });

for (const failed of [false, true])
  test(`unfiltered multi-format publication status silent failed=${failed}`, async () => {
    const { dir, cleanup } = await createFixture({
      'entry.cjs': failed ? 'console.log(import.meta.url);' : 'console.log(42);',
    });
    try {
      if (!process.env.ZNTC_LOOP_CAPTURE_NAPI) init();
      const files = [join(dir, 'output.cjs'), join(dir, 'output.mjs')];
      for (const file of files) writeFileSync(file, 'multi-format sentinel\n');
      const result = await build({
        entryPoints: [join(dir, 'entry.cjs')],
        logLevel: 'silent',
        write: true,
        output: [
          { format: 'cjs', file: files[0] },
          { format: 'esm', file: files[1] },
        ],
      });
      expect(result.hasErrors).toBe(failed);
      expect(result.errors).toEqual([]);
      expect(result.warnings).toEqual([]);
      expect(result.outputsByFormat).toHaveLength(2);
      for (const file of files) {
        const written = readFileSync(file, 'utf8');
        if (failed) expect(written).toBe('multi-format sentinel\n');
        else expect(written).toContain('42');
      }
    } finally {
      await cleanup();
    }
  });

for (const api of ['sync', 'async'] as const)
  for (const phase of ['onBuildEnd', 'onCloseBundle'] as const)
    test(`unfiltered lifecycle status ${api} ${phase}`, async () => {
      const { dir, cleanup } = await createFixture({ 'entry.cjs': 'console.log(42);' });
      try {
        if (!process.env.ZNTC_LOOP_CAPTURE_NAPI) init();
        const outfile = join(dir, 'output.cjs');
        const options: BuildOptions = {
          entryPoints: [join(dir, 'entry.cjs')],
          outfile,
          format: 'cjs',
          write: true,
          plugins: [
            {
              name: 'failure-status',
              setup(hooks) {
                hooks[phase](() => {
                  throw new Error('lifecycle failure status');
                });
              },
            },
          ],
        };
        const result = api === 'sync' ? buildSync(options) : await build(options);
        expect(result.hasErrors).toBe(true);
        expect(result.errors.some((diagnostic) => diagnostic.code === 'plugin_error')).toBe(true);
        // Preserve lifecycle order: closeBundle runs after writing, buildEnd before.
        expect(existsSync(outfile)).toBe(phase === 'onCloseBundle');
      } finally {
        await cleanup();
      }
    });
