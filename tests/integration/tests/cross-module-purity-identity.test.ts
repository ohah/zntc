import { describe, expect, test } from 'bun:test';
import { join } from 'node:path';
import { writeFile } from 'node:fs/promises';
import { createFixture, runNode, ZNTC_BIN } from './helpers';

async function run(cmd: string[]) {
  const child = Bun.spawn({ cmd, stdout: 'pipe', stderr: 'pipe' });
  const [stdout, stderr, status] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  return { stdout, stderr, status };
}

describe('cross-module purity uses the actual export binding', () => {
  for (const pure of [false, true]) {
    test(pure ? 'aliased pure declaration' : 'same-named pure sibling', async () => {
      const fixture = await createFixture({
        'package.json': '{"type":"module"}',
        'entry.mjs': "import{visible}from'./provider.mjs';visible();",
        'provider.mjs': pure
          ? "function visible(){console.log('sibling')}/* @__NO_SIDE_EFFECTS__ */ function actual(){return 7}export{actual as visible};"
          : "/* @__NO_SIDE_EFFECTS__ */ function visible(){}function actual(){console.log('side')}export{actual as visible};",
      });
      try {
        const entry = join(fixture.dir, 'entry.mjs');
        const native = await runNode(entry);
        expect(native.stdout).toBe(pure ? '' : 'side');
        for (const mode of ['plain', 'identifiers', 'full']) {
          const outfile = join(fixture.dir, `output-${mode}.mjs`);
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
            '--platform=node',
            '--format=esm',
            '-o',
            outfile,
            ...flags,
          ]);
          expect(cli.status, cli.stderr).toBe(0);
          expect((await runNode(outfile)).stdout).toBe(native.stdout);
          const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
          const script = [
            `import {build} from ${JSON.stringify(coreEntry)};`,
            `const r=await build(${JSON.stringify({ entryPoints: [entry], platform: 'node', format: 'esm', outfile, minifyIdentifiers: mode !== 'plain', minifySyntax: mode === 'full', minifyWhitespace: mode === 'full', diskCache: false, write: false })});`,
            'if(r.errors.length){console.error(JSON.stringify(r.errors));process.exit(1)}',
            'if(r.outputFiles.length!==1)throw new Error("expected one output");',
            'process.stdout.write(r.outputFiles[0].text);',
          ].join('\n');
          const napi = await run(['bun', '-e', script]);
          expect(napi.status, napi.stderr).toBe(0);
          await writeFile(outfile, napi.stdout);
          expect((await runNode(outfile)).stdout).toBe(native.stdout);
          // Check the annotation itself: a wrong annotation need not cause DCE
          // for this particular fixture to violate the purity contract.
          if (mode === 'plain' && !pure)
            expect(/\/\*\s*@__PURE__\s*\*\/\s*actual\(/.test(napi.stdout)).toBe(false);
        }
      } finally {
        await fixture.cleanup();
      }
    });
  }
});
