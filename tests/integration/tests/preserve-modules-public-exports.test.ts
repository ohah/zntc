import { describe, expect, test } from 'bun:test';
import { readdir, realpath, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { build, close, init } from '../../../packages/core/index';
import { createFixture } from './helpers';

const cases = [
  [
    'anonymous-function',
    "import{value}from'./dep.mjs';export default function(){return value()}",
    'ns.default()',
  ],
  [
    'named-function',
    "import{value}from'./dep.mjs';export default function read(){return value()}",
    'ns.default()',
  ],
  ['arrow-expression', "import{value}from'./dep.mjs';export default ()=>value()", 'ns.default()'],
  [
    'class-expression',
    "import{value}from'./dep.mjs';export default class{read(){return value()}}",
    'new ns.default().read()',
  ],
  [
    'named-class',
    "import{value}from'./dep.mjs';export default class Box{read(){return value()}}",
    'new ns.default().read()',
  ],
  [
    'object-expression',
    "import{value}from'./dep.mjs';export default {read(){return value()}}",
    'ns.default.read()',
  ],
  [
    'live-alias',
    "import{value}from'./dep.mjs';function read(){return value()}export{read as default}",
    'ns.default()',
  ],
  ['reexport-default', "export{value as default}from'./dep.mjs'", 'ns.default()'],
  [
    'star-and-default',
    "export*from'./dep.mjs';import{value}from'./dep.mjs';export default function(){return value()}",
    'ns.default()+ns.value()-42',
  ],
  [
    'wrapper-name-alias',
    "import{value}from'./dep.mjs';export{value as init_entry};export default function(){return value()}",
    'ns.default()+ns.init_entry()-42',
  ],
] as const;

describe('preserve-modules public exports and actual guarded source callers', () => {
  for (const [name, source, read] of cases)
    for (const minify of [false, true]) {
      test(`${name} ${minify ? 'minify' : 'plain'}`, async () => {
        const { dir, cleanup } = await createFixture({
          'package.json': '{"type":"module"}',
          'entry.mjs': source,
          'dep.mjs': 'export function value(){return 42}',
        });
        try {
          const execute = (file: string) =>
            spawnSync(
              'node',
              [
                '--input-type=module',
                '-e',
                `const ns=await import(${JSON.stringify(pathToFileURL(file).href)});console.log(${read});`,
              ],
              { encoding: 'utf8' },
            );
          const native = execute(join(dir, 'entry.mjs'));
          expect(native.status).toBe(0);
          expect(native.stdout).toBe('42\n');
          await init();
          try {
            const result = await build({
              entryPoints: [join(dir, 'entry.mjs')],
              rootDir: dir,
              outdir: join(dir, 'out'),
              write: true,
              platform: 'react-native',
              format: 'esm',
              splitting: true,
              preserveModules: true,
              minify,
            });
            expect(result.errors).toEqual([]);
          } finally {
            close();
          }
          await writeFile(join(dir, 'out/package.json'), '{"type":"module"}');
          const actual = execute(join(dir, 'out/entry.js'));
          expect(actual.stderr).toBe('');
          expect(actual.status).toBe(0);
          expect(actual.stdout).toBe(native.stdout);
        } finally {
          await cleanup();
        }
      });
    }
});

describe('preserve-modules output path and unused guard controls', () => {
  for (const minify of [false, true]) {
    test(`nested source imports root-level guard provider minify=${minify}`, async () => {
      const { dir, cleanup } = await createFixture({
        'package.json': '{"type":"module"}',
        'src/entry.mjs': "import{value}from'../lib/dep.mjs';export default ()=>value();",
        'lib/dep.mjs': 'export function value(){return 42}',
      });
      try {
        const sourceRoot = await realpath(dir);
        await init();
        try {
          const result = await build({
            entryPoints: [join(sourceRoot, 'src/entry.mjs')],
            rootDir: dir,
            outdir: join(dir, 'out'),
            write: true,
            platform: 'react-native',
            format: 'esm',
            splitting: true,
            preserveModules: true,
            preserveModulesRoot: sourceRoot,
            minify,
          });
          expect(result.errors).toEqual([]);
        } finally {
          close();
        }
        const actual = spawnSync(
          'node',
          [
            '--input-type=module',
            '-e',
            `const ns=await import(${JSON.stringify(pathToFileURL(join(dir, 'out/src/entry.js')).href)});console.log(ns.default());`,
          ],
          { encoding: 'utf8' },
        );
        expect(actual.stderr).toBe('');
        expect(actual.status).toBe(0);
        expect(actual.stdout).toBe('42\n');
        expect(await readdir(join(dir, 'out'))).toContain('runtime-split-entry-guard.js');
      } finally {
        await cleanup();
      }
    });
    test(`unused guard provider is not emitted minify=${minify}`, async () => {
      const { dir, cleanup } = await createFixture({
        'package.json': '{"type":"module"}',
        'entry.mjs': 'export default 42;',
      });
      try {
        await init();
        try {
          const result = await build({
            entryPoints: [join(dir, 'entry.mjs')],
            rootDir: dir,
            outdir: join(dir, 'out'),
            write: true,
            platform: 'react-native',
            format: 'esm',
            splitting: true,
            preserveModules: true,
            minify,
          });
          expect(result.errors).toEqual([]);
        } finally {
          close();
        }
        expect(await readdir(join(dir, 'out'))).not.toContain('runtime-split-entry-guard.js');
        const actual = spawnSync(
          'node',
          [
            '--input-type=module',
            '-e',
            `const ns=await import(${JSON.stringify(pathToFileURL(join(dir, 'out/entry.js')).href)});console.log(ns.default);`,
          ],
          { encoding: 'utf8' },
        );
        expect(actual.stderr).toBe('');
        expect(actual.status).toBe(0);
        expect(actual.stdout).toBe('42\n');
      } finally {
        await cleanup();
      }
    });
  }
});
