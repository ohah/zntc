import { describe, expect, test } from 'bun:test';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createFixture, runNode, ZNTC_BIN } from './helpers';

const dependency = String.raw`const value=7;export {value,value as "q word",value as "literal\\u0061"};export const other=5;export default 11;`;
const cases = [
  {
    name: 'named',
    source: "import {value as local} from './dep.mjs';console.log(local);",
    expected: '7',
  },
  { name: 'default', source: "import local from './dep.mjs';console.log(local);", expected: '11' },
  {
    name: 'namespace',
    source: "import * as local from './dep.mjs';console.log(local.value);",
    expected: '7',
  },
  {
    name: 'duplicate aliases',
    source:
      "import {value as a} from './dep.mjs';import {value as b} from './dep.mjs';console.log(a+b);",
    expected: '14',
  },
  {
    name: 'independent providers',
    source:
      "import {value as a} from './dep.mjs';import {value as b} from './other.mjs';console.log(a+b);",
    expected: '20',
  },
  {
    name: 'same declaration sibling aliases',
    source: "import {value as a,value as b} from './dep.mjs';console.log(a+b);",
    expected: '14',
  },
  {
    name: 'escaped local',
    source: String.raw`import {value as l\u006fcal} from './dep.mjs';console.log(local);`,
    expected: '7',
  },
  {
    name: 'quoted property',
    source: 'import {"q word" as local} from "./dep.mjs";console.log(local);',
    expected: '7',
  },
  {
    name: 'literal backslash property',
    source: String.raw`import {"literal\\u0061" as local} from './dep.mjs';console.log(local);`,
    expected: '7',
  },
  {
    name: 'escaped property',
    source: String.raw`import {"v\u0061lue" as local} from './dep.mjs';console.log(local);`,
    expected: '7',
  },
  {
    name: 'generated JSX helper collides with source local',
    source: 'const _jsx=5;const el=<div value={7}/>;console.log(el.props.value+_jsx);',
    // JSX needs lowering before Node can execute it. This independent JS
    // oracle uses the same external runtime protocol, with its own local name.
    oracle:
      "import {jsx as create} from 'react/jsx-runtime';const _jsx=5;console.log(create('div',{value:7}).props.value+_jsx);",
    extension: 'jsx',
    expected: '12',
  },
];

async function run(cmd: string[], coverage = false) {
  const env = { ...process.env };
  delete env.ZNTC_DEBUG_SYMBOL_COVERAGE;
  delete env.ZNTC_DEBUG_SYNTHETIC_COVERAGE;
  if (coverage) env.ZNTC_DEBUG_SYMBOL_COVERAGE = '1';
  const child = Bun.spawn({ cmd, env, stdout: 'pipe', stderr: 'pipe' });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  return { stdout, stderr, exitCode, pid: child.pid };
}

describe('external import identity public runtime', () => {
  for (const item of cases) {
    test(
      item.name,
      async () => {
        const name = `entry.${item.extension ?? 'mjs'}`;
        const fixture = await createFixture({
          [name]: item.source,
          'native.mjs': item.oracle ?? item.source,
          'dep.mjs': dependency,
          'other.mjs': 'export const value=13;',
          'node_modules/react/package.json': JSON.stringify({
            name: 'react',
            type: 'module',
            exports: { './jsx-runtime': './jsx-runtime.mjs' },
          }),
          'node_modules/react/jsx-runtime.mjs':
            'export function jsx(type,props){return {type,props}}export const jsxs=jsx;export const Fragment=Symbol.for("fragment");',
        });
        try {
          const entry = join(fixture.dir, name);
          const output = join(fixture.dir, 'output.mjs');
          const before = await readFile(entry, 'utf8');
          const native = await runNode(join(fixture.dir, 'native.mjs'));
          expect(native.stdout).toBe(item.expected);
          for (const mode of ['plain', 'identifiers', 'full']) {
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
              '--format=esm',
              '--platform=node',
              '--target=esnext',
              '--jsx=automatic',
              '--external:./dep.mjs',
              '--external:./other.mjs',
              '--external:react/jsx-runtime',
              ...flags,
              '-o',
              output,
            ]);
            expect(cli.exitCode, cli.stderr).toBe(0);
            expect((await runNode(output)).stdout).toBe(native.stdout);
            for (const treeShaking of [false, true]) {
              for (const coverage of [false, true]) {
                const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
                const script = [
                  `import {build} from ${JSON.stringify(coreEntry)};`,
                  `const result=await build(${JSON.stringify({ entryPoints: [entry], outfile: output, platform: 'node', format: 'esm', target: 'esnext', jsx: 'automatic', external: ['./dep.mjs', './other.mjs', 'react/jsx-runtime'], minifyIdentifiers: mode !== 'plain', minifySyntax: mode === 'full', minifyWhitespace: mode === 'full', treeShaking, diskCache: false, write: false })});`,
                  'if(result.errors.length){console.error(JSON.stringify(result.errors));process.exit(1)}',
                  'process.stdout.write(JSON.stringify(result.outputFiles.map(file=>file.text)));',
                ].join('\n');
                const built = await run(['bun', '-e', script], coverage);
                expect(built.exitCode, built.stderr).toBe(0);
                const outputs = JSON.parse(built.stdout) as string[];
                expect(outputs).toHaveLength(1);
                await writeFile(output, outputs[0]);
                expect((await runNode(output)).stdout).toBe(native.stdout);
              }
            }
          }
          expect(await readFile(entry, 'utf8')).toBe(before);
        } finally {
          await fixture.cleanup();
        }
      },
      60_000,
    );
  }
});
