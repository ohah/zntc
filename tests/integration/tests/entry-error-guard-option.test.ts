import { describe, expect, test } from 'bun:test';
import { spawn } from 'bun';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { build, buildSync, close, init, type BuildOptions } from '../../../packages/core/index';
import { createFixture } from './helpers';

const inputs = [
  {
    name: 'default import',
    entry: "import read from './dep.mjs';export default()=>read()",
    dep: 'export default function read(){return 42}',
  },
  {
    name: 'namespace receiver',
    entry: "import*as ns from './dep.mjs';export default()=>ns.read()",
    dep: 'export const marker=42;export function read(){return this.marker}',
  },
  {
    name: 'side effect import',
    entry: "import './dep.mjs';export default()=>globalThis.guardOptionAnswer",
    dep: 'globalThis.guardOptionAnswer=42',
  },
] as const;

describe('entryErrorGuard explicit booleans override the platform default', () => {
  for (const api of ['sync', 'async'] as const)
    for (const platform of ['react-native', 'node', 'browser'] as const)
      for (const entryErrorGuard of [false, true, undefined])
        for (const format of ['esm', 'cjs'] as const)
          for (const minify of platform === 'react-native' ? [false, true] : [false])
            for (const input of platform === 'react-native' ? inputs : inputs.slice(0, 1)) {
              test(`${api} ${platform} ${String(entryErrorGuard)} ${format} minify=${minify} ${input.name}`, async () => {
                const { dir, cleanup } = await createFixture({
                  'package.json': JSON.stringify({
                    type: format === 'esm' ? 'module' : 'commonjs',
                  }),
                  'entry.mjs': input.entry,
                  'dep.mjs': input.dep,
                });
                try {
                  init();
                  const options: BuildOptions = {
                    entryPoints: [join(dir, 'entry.mjs')],
                    rootDir: dir,
                    outdir: join(dir, 'out'),
                    write: true,
                    platform,
                    format,
                    outputExports: 'named',
                    splitting: true,
                    preserveModules: true,
                    strictExecutionOrder: true,
                    minify,
                    ...(entryErrorGuard === undefined ? {} : { entryErrorGuard }),
                  };
                  const result = api === 'sync' ? buildSync(options) : await build(options);
                  expect(result.errors).toEqual([]);
                  const file = join(dir, 'out/entry.js');
                  const load =
                    format === 'esm'
                      ? `await import(${JSON.stringify(pathToFileURL(file).href)})`
                      : `(await import('node:module')).createRequire(import.meta.url)(${JSON.stringify(file)})`;
                  const child = spawn({
                    cmd: [
                      'node',
                      '--input-type=module',
                      '-e',
                      `let reads=0;Object.defineProperty(globalThis,'ErrorUtils',{get(){reads++;return undefined}});const ns=${load};console.log(JSON.stringify([ns.default(),reads>0]));`,
                    ],
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
                  // Guards execute through the RN inline-require preset.
                  // Non-RN controls keep their existing eager import behavior.
                  const guarded = platform === 'react-native' && entryErrorGuard !== false;
                  expect(stdout).toBe(JSON.stringify([42, guarded]) + '\n');
                } finally {
                  close();
                  await cleanup();
                }
              });
            }
});
