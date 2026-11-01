import { describe, expect, test } from 'bun:test';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { createFixture, runNode, ZNTC_BIN } from './helpers';

const cases = [
  {
    name: 'function binding',
    provider: 'export function read(){return 7}',
    use: "import{read}from'./provider.mjs';export const value=read();",
  },
  {
    name: 'public alias',
    provider: 'function local(){return 7}export{local as read};',
    use: "import{read as local}from'./provider.mjs';export const value=local();",
  },
  {
    name: 'independent same spelling',
    provider: 'export function read(){return 7}',
    use: "import{read}from'./provider.mjs';export const value=read();",
    second: "import{read}from'./other.mjs';export const value=read();",
  },
  {
    name: 'escaped local datum',
    provider: String.raw`export function r\u0065ad(){return 7}`,
    use: "import{read}from'./provider.mjs';export const value=read();",
  },
  {
    name: 'quoted public key',
    provider: 'function local(){return 7}export{local as "q word"};',
    use: 'import{"q word" as read}from"./provider.mjs";export const value=read();',
  },
  {
    name: 'anonymous default facade',
    provider: 'export default function(){return 7}',
    use: "import read from'./provider.mjs';export const value=read();",
  },
  {
    name: 'namespace value escape',
    provider: 'export function read(){return 7}',
    use: "import*as ns from'./provider.mjs';function call(value){return value.read()}export const value=call(ns);",
  },
  {
    name: 'reexport carrier',
    provider: 'export function read(){return 7}',
    use: "import{read}from'./barrel.mjs';export const value=read();",
  },
  {
    name: 'live mutable export',
    provider:
      'export let current=7;export function read(){return current}export function keep(v){current=v}',
    use: "import{read,keep,current}from'./provider.mjs';keep(current);export const value=read();",
  },
  {
    name: 'receiver preserving object',
    provider: 'export const object={value:7,read(){return this.value}};',
    use: "import{object}from'./provider.mjs';export const value=object.read();",
  },
];

async function run(cmd: string[]) {
  const child = Bun.spawn({ cmd, stdout: 'pipe', stderr: 'pipe' });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  return { stdout, stderr, exitCode, pid: child.pid };
}

describe('cross chunk provider public runtime identity', () => {
  for (const item of cases) {
    test(
      item.name,
      async () => {
        const fixture = await createFixture({
          'package.json': '{"type":"module"}',
          'entry.mjs':
            "Promise.all([import('./a.mjs'),import('./b.mjs')]).then(([a,b])=>console.log(a.value,b.value));",
          'a.mjs': item.use,
          'b.mjs': item.second ?? item.use,
          'provider.mjs': item.provider,
          'other.mjs': 'export function read(){return 99}',
          'barrel.mjs': "export{read}from'./provider.mjs';",
        });
        try {
          const entry = join(fixture.dir, 'entry.mjs');
          const before = await readFile(entry, 'utf8');
          const native = await runNode(entry);
          expect(native.stdout).toBe(item.second ? '7 99' : '7 7');
          for (const format of ['esm', 'cjs']) {
            for (const layout of ['split', 'preserve']) {
              for (const mode of ['plain', 'identifiers', 'full']) {
                const outdir = join(fixture.dir, `${format}-${layout}-${mode}`);
                await mkdir(outdir, { recursive: true });
                await writeFile(
                  join(outdir, 'package.json'),
                  JSON.stringify({ type: format === 'esm' ? 'module' : 'commonjs' }),
                );
                const flags =
                  mode === 'plain'
                    ? []
                    : mode === 'identifiers'
                      ? ['--minify-identifiers']
                      : ['--minify'];
                const cli = await run([
                  ZNTC_BIN,
                  entry,
                  '--bundle',
                  `--format=${format}`,
                  '--platform=node',
                  '--target=esnext',
                  layout === 'split' ? '--splitting' : '--preserve-modules',
                  '--outdir',
                  outdir,
                  ...flags,
                ]);
                expect(cli.exitCode, cli.stderr).toBe(0);
                const cliEntry = join(outdir, 'entry.js');
                expect((await runNode(cliEntry)).stdout).toBe(native.stdout);
                const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
                for (const treeShaking of [false, true]) {
                  const script = [
                    `import {build} from ${JSON.stringify(coreEntry)};`,
                    `const result=await build(${JSON.stringify({ entryPoints: [entry], rootDir: fixture.dir, outdir, platform: 'node', format, target: 'esnext', splitting: layout === 'split', preserveModules: layout === 'preserve', minifyIdentifiers: mode !== 'plain', minifySyntax: mode === 'full', minifyWhitespace: mode === 'full', treeShaking, diskCache: false, write: false })});`,
                    'if(result.errors.length){console.error(JSON.stringify(result.errors));process.exit(1)}',
                    'process.stdout.write(JSON.stringify(result.outputFiles.map(file=>({path:file.path,text:file.text}))));',
                  ].join('\n');
                  const built = await run(['bun', '-e', script]);
                  expect(built.exitCode, built.stderr).toBe(0);
                  const outputs = JSON.parse(built.stdout) as { path: string; text: string }[];
                  expect(outputs.length).toBeGreaterThan(1);
                  for (const output of outputs) {
                    const file = join(outdir, output.path);
                    await mkdir(dirname(file), { recursive: true });
                    await writeFile(file, output.text);
                  }
                  const outputEntry = outputs.find((file) => /(?:^|\/)entry\.js$/.test(file.path));
                  expect(outputEntry).toBeDefined();
                  expect((await runNode(join(outdir, outputEntry!.path))).stdout).toBe(
                    native.stdout,
                  );
                }
              }
            }
          }
          expect(await readFile(entry, 'utf8')).toBe(before);
        } finally {
          await fixture.cleanup();
        }
      },
      120_000,
    );
  }
});
