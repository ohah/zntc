import { describe, expect, test } from 'bun:test';
import { join } from 'node:path';
import { readFile } from 'node:fs/promises';
import { buildSync, close, init } from '../../../packages/core/index';
import { createFixture } from './helpers';

const inputs = [
  ['simple', 'export function read(){return this===undefined}', 'read()'],
  ['default parameter', 'export function read(x=1){return this===undefined}', 'read()'],
  ['rest parameter', 'export function read(...x){return this===undefined}', 'read()'],
  ['destructured parameter', 'export function read({x}={x:1}){return this===undefined}', 'read()'],
  ['tag', 'export function read(){return this===undefined}', 'read`x`'],
  ['generator', 'export function* read(x=1){yield this===undefined}', 'read().next().value'],
  ['async', 'export async function read(x=1){return this===undefined}', 'await read()'],
  [
    'callee',
    'export function read(){try{return arguments.callee,false}catch(e){return e instanceof TypeError}}',
    'read()',
  ],
  [
    'assignment',
    'export function read(){try{globalThis.pmStrictUndeclared=undefined;delete globalThis.pmStrictUndeclared;pmStrictUndeclared=1;return false}catch(e){return e instanceof ReferenceError}}',
    'read()',
  ],
  ['eval', 'export function read(){let x=1;eval("var x=2");return x===1}', 'read()'],
] as const;

describe('preserve-modules CommonJS files preserve source strictness', () => {
  for (const hashbang of ['banner', 'intro'] as const)
    for (const platform of ['node', 'react-native'] as const)
      for (const [inputIndex, [name, dep, expression]] of inputs.entries())
        for (const minify of [false, true]) {
          const lineEnd = ['\n', '\r\n', '\r', '\u2028', '\u2029'][inputIndex % 5]!;
          test(`${hashbang} ${JSON.stringify(lineEnd)} ${platform} ${name} minify=${minify}`, async () => {
            const { dir, cleanup } = await createFixture({
              'entry.mjs': `import {read} from './dep.mjs';import sloppy from './sloppy.cjs';console.log(${expression},(0,sloppy)())`,
              'dep.mjs': `'use client';${dep}`,
              'sloppy.cjs': 'module.exports=function(){return this===globalThis}',
            });
            try {
              init();
              const result = buildSync({
                entryPoints: [join(dir, 'entry.mjs')],
                rootDir: dir,
                outdir: join(dir, 'out'),
                write: true,
                platform,
                format: 'cjs',
                splitting: true,
                preserveModules: true,
                strictExecutionOrder: true,
                entryErrorGuard: false,
                minify,
                banner:
                  hashbang === 'banner'
                    ? `#!/usr/bin/env node${lineEnd}globalThis.pmStrictBanner=1;`
                    : undefined,
                intro:
                  hashbang === 'intro'
                    ? `#!/usr/bin/env node${lineEnd}globalThis.pmStrictIntro=1;`
                    : 'globalThis.pmStrictIntro=1;',
              });
              expect(result.errors).toEqual([]);
              const child = Bun.spawn(['node', join(dir, 'out/entry.js')], {
                stdout: 'pipe',
                stderr: 'pipe',
              });
              const [stdout, stderr, status] = await Promise.all([
                new Response(child.stdout).text(),
                new Response(child.stderr).text(),
                child.exited,
              ]);
              expect(status).toBe(0);
              expect(stderr).toBe('');
              expect(stdout).toBe('true true\n');
              const output = await readFile(join(dir, 'out/dep.js'), 'utf8');
              expect(output).toMatch(/^#!\/usr\/bin\/env node(?:\r\n|[\n\r\u2028\u2029])/);
              expect(output.indexOf('"use strict";')).toBeGreaterThanOrEqual(0);
              expect(output.indexOf('"use strict";')).toBeLessThan(
                output.indexOf(
                  hashbang === 'banner' ? 'globalThis.pmStrictBanner' : 'globalThis.pmStrictIntro',
                ),
              );
            } finally {
              close();
              await cleanup();
            }
          });
        }
});
