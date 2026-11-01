import { describe, expect, test } from 'bun:test';
import { dirname, join } from 'node:path';
import { mkdir, writeFile } from 'node:fs/promises';
import { createFixture, runNode, ZNTC_BIN } from './helpers';

const cases = [
  { name: 'bare import', prefix: "import './shared.cjs';" },
  { name: 'empty import', prefix: "import{}from'./shared.cjs';" },
  { name: 'empty re-export', prefix: "export{}from'./shared.cjs';" },
  { name: 'duplicate imports', prefix: "import './shared.cjs';import './shared.cjs';" },
  {
    name: 'mixed empty clauses',
    prefix: "import{}from'./shared.cjs';export{}from'./shared.cjs';import './shared.cjs';",
  },
  {
    name: 'shared ESM barrel',
    prefix: "import './barrel.mjs';",
    files: { 'barrel.mjs': "import './shared.cjs';" },
  },
  {
    name: 'independent same-basename wrappers',
    prefix: "import './left/shared.cjs';import './right/shared.cjs';",
    files: {
      'left/shared.cjs': "console.log('left');module.exports=7;",
      'right/shared.cjs': "console.log('right');module.exports=9;",
    },
  },
  {
    name: 'mixed ESM and CJS effects',
    prefix: "import './effect.mjs';import './shared.cjs';",
    files: { 'effect.mjs': "console.log('esm');export const unused=1;" },
  },
  { name: 'default value import control', prefix: "import value from'./shared.cjs';", value: true },
  {
    name: 'lazy import control',
    prefix: '',
    lazy: true,
  },
];

async function run(cmd: string[]) {
  const child = Bun.spawn({ cmd, stdout: 'pipe', stderr: 'pipe' });
  const [stdout, stderr, status] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  return { stdout, stderr, status };
}

describe('shared CJS evaluation retains its wrapper binding', () => {
  for (const item of cases) {
    test(
      item.name,
      async () => {
        const entrySource = (letter: string) =>
          item.lazy
            ? `void(async()=>{console.log('before-${letter}');const ns=await import('./shared.cjs');console.log('entry-${letter}',ns.default)})();`
            : `${item.prefix}console.log('entry-${letter}'${item.value ? ',value' : ''});`;
        const fixture = await createFixture({
          'package.json': '{"type":"module"}',
          'shared.cjs': "console.log('side');module.exports=7;",
          ...item.files,
          'entry-a.mjs': entrySource('a'),
          'entry-b.mjs': entrySource('b'),
        });
        try {
          const entries = ['a', 'b'].map((letter) => join(fixture.dir, `entry-${letter}.mjs`));
          const native = await Promise.all(entries.map((file) => runNode(file)));
          expect(native[0].stdout).toContain('entry-a');
          expect(native[1].stdout).toContain('entry-b');
          for (const format of ['esm', 'cjs']) {
            for (const mode of ['plain', 'identifiers', 'full']) {
              const outdir = join(fixture.dir, `${format}-${mode}`);
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
                '--bundle',
                ...entries,
                '--platform=node',
                `--format=${format}`,
                '--splitting',
                '--outdir',
                outdir,
                ...flags,
              ]);
              expect(cli.status, cli.stderr).toBe(0);
              for (const [index, letter] of ['a', 'b'].entries())
                expect((await runNode(join(outdir, `entry-${letter}.js`))).stdout).toBe(
                  native[index].stdout,
                );
              const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
              const script = [
                `import {build} from ${JSON.stringify(coreEntry)};`,
                `const r=await build(${JSON.stringify({ entryPoints: entries, rootDir: fixture.dir, platform: 'node', format, outdir, splitting: true, minifyIdentifiers: mode !== 'plain', minifySyntax: mode === 'full', minifyWhitespace: mode === 'full', diskCache: false, write: false })});`,
                'if(r.errors.length){console.error(JSON.stringify(r.errors));process.exit(1)}',
                'process.stdout.write(JSON.stringify(r.outputFiles.map(f=>({path:f.path,text:f.text}))));',
              ].join('\n');
              const napi = await run(['bun', '-e', script]);
              expect(napi.status, napi.stderr).toBe(0);
              const outputs = JSON.parse(napi.stdout) as { path: string; text: string }[];
              expect(outputs.length).toBeGreaterThan(2);
              for (const output of outputs) {
                const file = join(outdir, output.path);
                await mkdir(dirname(file), { recursive: true });
                await writeFile(file, output.text);
              }
              for (const [index, letter] of ['a', 'b'].entries())
                expect((await runNode(join(outdir, `entry-${letter}.js`))).stdout).toBe(
                  native[index].stdout,
                );
            }
          }
        } finally {
          await fixture.cleanup();
        }
      },
      120_000,
    );
  }
});
