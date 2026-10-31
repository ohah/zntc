import { describe, expect, test } from 'bun:test';
import { readFile, readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { createFixture, runNode, ZNTC_BIN } from './helpers';

const cases = [
  {
    name: 'two scalar exports',
    source:
      "export const a=3;export const b=7;import*as ns from './entry.mjs';console.log(JSON.stringify([Reflect.get(ns,'a'),Reflect.get(ns,'b')]));",
    expected: '[3,7]',
  },
  {
    name: 'declaration order differs from read order',
    source:
      "export const b=7;export const a=3;import*as ns from './entry.mjs';console.log(JSON.stringify([Reflect.get(ns,'a'),Reflect.get(ns,'b')]));",
    expected: '[3,7]',
  },
  {
    name: 'import precedes both declarations',
    source:
      "import*as ns from './entry.mjs';export const a=3;export const b=7;console.log(JSON.stringify([Reflect.get(ns,'a'),Reflect.get(ns,'b')]));",
    expected: '[3,7]',
  },
  {
    name: 'source expression statements keep their order',
    source:
      "console.log('before');export const a=3;console.log('between');export const b=7;import*as ns from './entry.mjs';console.log(JSON.stringify([Reflect.get(ns,'a'),Reflect.get(ns,'b')]));",
    expected: 'before\nbetween\n[3,7]',
  },
  // These controls require native equivalence, without admitting a new AST plan.
  {
    name: 'a read before the second declaration keeps native behavior',
    source:
      "export const a=3;import*as ns from './entry.mjs';console.log(Reflect.get(ns,'a'));export const b=7;console.log(JSON.stringify([Reflect.get(ns,'a'),Reflect.get(ns,'b')]));",
    expected: '3\n[3,7]',
  },
  {
    name: 'mutable exports keep live namespace reads',
    source:
      "export let a=3;export const b=7;import*as ns from './entry.mjs';a=5;console.log(JSON.stringify([Reflect.get(ns,'a'),Reflect.get(ns,'b')]));",
    expected: '[5,7]',
  },
] as const;

async function run(cmd: string[]) {
  const env = { ...process.env };
  delete env.ZNTC_DEBUG_SYMBOL_COVERAGE;
  delete env.ZNTC_DEBUG_SYNTHETIC_COVERAGE;
  const child = Bun.spawn({ cmd, env, stdout: 'pipe', stderr: 'pipe' });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  return { stdout, stderr, exitCode, pid: child.pid };
}

async function cacheFileCount(cacheDir: string) {
  const entries = await readdir(cacheDir, { recursive: true, withFileTypes: true });
  return entries.filter((entry) => entry.isFile()).length;
}

// Runtime and persisted-cache equivalence are public observations. Native graph
// tests separately prove the actual holder plan, SID/scope links, and cache hits.
describe('namespace identity public runtime', () => {
  for (const fixtureCase of cases) {
    for (const api of ['CLI', 'NAPI tree-shaking on', 'NAPI tree-shaking off'] as const) {
      test(`${fixtureCase.name}: ${api} preserves cold and warm runtime`, async () => {
        const fixture = await createFixture({ 'entry.mjs': fixtureCase.source });
        try {
          const entry = join(fixture.dir, 'entry.mjs');
          const output = join(fixture.dir, 'output.mjs');
          const cacheDir = join(fixture.dir, 'cache');
          const native = await runNode(entry);
          expect(native.stdout).toBe(fixtureCase.expected);
          const sourceBefore = await readFile(entry, 'utf8');
          let coldOutput: string | undefined;
          let coldPid: number | undefined;

          for (const phase of ['cold', 'warm'] as const) {
            const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
            const runner = [
              `import { build } from ${JSON.stringify(coreEntry)};`,
              `const result = await build(${JSON.stringify({
                entryPoints: [entry],
                outfile: output,
                platform: 'node',
                format: 'esm',
                target: 'esnext',
                minifyIdentifiers: false,
                minifySyntax: false,
                minifyWhitespace: false,
                treeShaking: api !== 'NAPI tree-shaking off',
                diskCache: true,
                cacheDir,
                write: true,
              })});`,
              'if (result.errors.length) { console.error(JSON.stringify(result.errors)); process.exit(1); }',
              'console.log(JSON.stringify({ pid: process.pid, outputs: result.outputFiles.map(file => file.path) }));',
            ].join('\n');
            // A fresh process for each phase prevents an in-memory store from
            // substituting for the cross-process disk-cache exercise.
            const built = await run(
              api === 'CLI'
                ? [
                    ZNTC_BIN,
                    '--bundle',
                    entry,
                    '--platform=node',
                    '--format=esm',
                    '--target=esnext',
                    '--cache-dir',
                    cacheDir,
                    '-o',
                    output,
                  ]
                : ['bun', '-e', runner],
            );
            expect(built.exitCode, `${api} ${phase}: ${built.stderr}`).toBe(0);
            if (phase === 'cold') coldPid = built.pid;
            else expect(built.pid).not.toBe(coldPid);
            if (api !== 'CLI') {
              const metadata = JSON.parse(built.stdout) as { pid: number; outputs: string[] };
              expect(metadata.pid).toBe(built.pid);
              // outputFiles uses virtual paths; outfile is verified on disk
              // by the Node execution and read below.
              expect(metadata.outputs).toHaveLength(1);
            }
            expect(await cacheFileCount(cacheDir)).toBeGreaterThan(0);
            const actual = await runNode(output);
            expect(actual.stdout).toBe(native.stdout);
            const emitted = await readFile(output, 'utf8');
            if (phase === 'cold') coldOutput = emitted;
            else expect(emitted).toBe(coldOutput);
            expect(await readFile(entry, 'utf8')).toBe(sourceBefore);
          }
        } finally {
          await fixture.cleanup();
        }
      }, 30_000);
    }
  }
});
