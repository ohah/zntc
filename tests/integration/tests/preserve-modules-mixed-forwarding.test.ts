import { describe, expect, test } from 'bun:test';
import { spawn } from 'bun';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { build, close, init } from '../../../packages/core/index';
import { createFixture, ZNTC_BIN } from './helpers';

// Frozen ten-input corpus SHA-256 e62ce756ca122c2b301aada2cb747079ab9fa8eeb52c206cc489c9969cbd9875.
const cases = [
  {
    name: 'default-arrow-local-reexport',
    files: {
      'entry.mjs': "import run,{value}from'./provider.mjs';export default()=>[run(),value()]",
      'provider.mjs': "import{value}from'./dep.mjs';export{value};export default()=>value()",
      'dep.mjs': 'export function value(){return 42}',
    },
    read: 'ns.default()',
  },
  {
    name: 'default-function-local-reexport',
    files: {
      'entry.mjs': "import run,{value}from'./provider.mjs';export default()=>[run(),value()]",
      'provider.mjs':
        "import{value}from'./dep.mjs';export{value};export default function run(){return value()}",
      'dep.mjs': 'export function value(){return 42}',
    },
    read: 'ns.default()',
  },
  {
    name: 'default-class-local-reexport',
    files: {
      'entry.mjs':
        "import Run,{value}from'./provider.mjs';export default()=>[new Run().run(),value()]",
      'provider.mjs':
        "import{value}from'./dep.mjs';export{value};export default class Run{run(){return value()}}",
      'dep.mjs': 'export function value(){return 42}',
    },
    read: 'ns.default()',
  },
  {
    name: 'default-expression-snapshot',
    files: {
      'entry.mjs': "import run,{value}from'./provider.mjs';export default()=>[run(),value()]",
      'provider.mjs':
        "import{value}from'./dep.mjs';export{value};const run=()=>value();export default run",
      'dep.mjs': 'export function value(){return 42}',
    },
    read: 'ns.default()',
  },
  {
    name: 'default-alias-syntax',
    files: {
      'entry.mjs':
        "import{default as run,value}from'./provider.mjs';export default()=>[run(),value()]",
      'provider.mjs': "import{value}from'./dep.mjs';export{value};export default()=>value()",
      'dep.mjs': 'export function value(){return 42}',
    },
    read: 'ns.default()',
  },
  {
    name: 'namespace-mixed-forward',
    files: {
      'entry.mjs':
        "import*as ns from'./provider.mjs';import{value}from'./provider.mjs';export default()=>[ns.default(),value()]",
      'provider.mjs': "import{value}from'./dep.mjs';export{value};export default()=>value()",
      'dep.mjs': 'export function value(){return 42}',
    },
    read: 'ns.default()',
  },
  {
    name: 'quoted-private-collision',
    files: {
      'entry.mjs':
        "import run,{'init_provider' as value}from'./provider.mjs';export default()=>[run(),value()]",
      'provider.mjs':
        "import{value}from'./dep.mjs';export{value as 'init_provider'};export default()=>value()",
      'dep.mjs': 'export function value(){return 42}',
    },
    read: 'ns.default()',
  },
  {
    name: 'escaped-private-collision',
    files: {
      'entry.mjs':
        "import run,{'\\u0069nit_provider' as value}from'./provider.mjs';export default()=>[run(),value()]",
      'provider.mjs':
        "import{value}from'./dep.mjs';export{value as '\\u0069nit_provider'};export default()=>value()",
      'dep.mjs': 'export function value(){return 42}',
    },
    read: 'ns.default()',
  },
  {
    name: 'two-forwarded-names',
    files: {
      'entry.mjs':
        "import run,{value,other}from'./provider.mjs';export default()=>[run(),value()+other()-42]",
      'provider.mjs':
        "import{value,other}from'./dep.mjs';export{value,other};export default()=>value()",
      'dep.mjs': 'export function value(){return 42}export function other(){return 42}',
    },
    read: 'ns.default()',
  },
  {
    name: 'explicit-from-reexport',
    files: {
      'entry.mjs': "import run,{value}from'./provider.mjs';export default()=>[run(),value()]",
      'provider.mjs':
        "import{value}from'./dep.mjs';export{value}from'./dep.mjs';export default()=>value()",
      'dep.mjs': 'export function value(){return 42}',
    },
    read: 'ns.default()',
  },
] as const;

async function execute(command: string, args: string[]) {
  const child = spawn({ cmd: [command, ...args], stdout: 'pipe', stderr: 'pipe' });
  const [stdout, stderr, status] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  return { stdout, stderr, status };
}

describe('mixed forwarded imports keep exact value identities and own eager evaluation', () => {
  for (const entry of cases)
    for (const format of ['esm', 'cjs'] as const)
      for (const guarded of [false, true])
        for (const minify of [false, true])
          test(`${entry.name} ${format} guard=${guarded} minify=${minify}`, async () => {
            const { dir, cleanup } = await createFixture({
              'package.json': JSON.stringify({ type: format === 'esm' ? 'module' : 'commonjs' }),
              ...entry.files,
            });
            try {
              const native = await execute('node', [
                '--input-type=module',
                '-e',
                `const ns=await import(${JSON.stringify(pathToFileURL(join(dir, 'entry.mjs')).href)});console.log(JSON.stringify(${entry.read}));`,
              ]);
              expect(native.status).toBe(0);
              expect(native.stderr).toBe('');
              expect(native.stdout).toBe('[42,42]\n');
              const outdir = join(dir, 'out');
              if (guarded) {
                await init();
                try {
                  const result = await build({
                    entryPoints: [join(dir, 'entry.mjs')],
                    rootDir: dir,
                    outdir,
                    write: true,
                    platform: 'react-native',
                    format,
                    outputExports: 'named',
                    splitting: true,
                    preserveModules: true,
                    strictExecutionOrder: true,
                    entryErrorGuard: true,
                    minify,
                  });
                  expect(result.errors).toEqual([]);
                } finally {
                  close();
                }
              } else {
                // Native CLI has a real false guard policy. NAPI RN currently ORs false with its preset.
                const result = await execute(ZNTC_BIN, [
                  '--bundle',
                  join(dir, 'entry.mjs'),
                  '--platform=react-native',
                  '--format=' + format,
                  '--output-exports=named',
                  '--splitting',
                  '--preserve-modules',
                  '--preserve-modules-root=' + dir,
                  '--outdir',
                  outdir,
                  ...(minify ? ['--minify'] : []),
                ]);
                expect(result.status).toBe(0);
              }
              const file = join(outdir, 'entry.js');
              const load =
                format === 'esm'
                  ? `await import(${JSON.stringify(pathToFileURL(file).href)})`
                  : `(await import('node:module')).createRequire(import.meta.url)(${JSON.stringify(file)})`;
              const actual = await execute('node', [
                '--input-type=module',
                '-e',
                `let reads=0;Object.defineProperty(globalThis,'ErrorUtils',{get(){reads++;return undefined}});const ns=${load};console.log(JSON.stringify(${entry.read}));console.log(reads);`,
              ]);
              expect(actual.status).toBe(0);
              expect(actual.stderr).toBe('');
              const lines = actual.stdout.trimEnd().split('\n');
              expect(lines[0] + '\n').toBe(native.stdout);
              if (guarded) expect(Number(lines[1])).toBeGreaterThan(0);
              else expect(Number(lines[1])).toBe(0);
            } finally {
              await cleanup();
            }
          });
});
