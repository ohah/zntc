import { describe, expect, test } from 'bun:test';
import { spawn } from 'bun';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createFixture, ZNTC_BIN } from './helpers';
async function execute(command: string, args: string[]) {
  const child = spawn({ cmd: [command, ...args], stdout: 'pipe', stderr: 'pipe' });
  const [stdout, stderr, status] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  return { status, stdout, stderr };
}
const cases = [
  {
    name: 'default-function',
    files: {
      'entry.mjs': "import value from'./dep.mjs';export default()=>value()",
      'dep.mjs': 'export default function value(){return 42}',
    },
    read: 'ns.default()',
    expected: '42\n',
    guardReads: 1,
  },
  {
    name: 'default-expression',
    files: {
      'entry.mjs': "import value from'./dep.mjs';export default()=>value()",
      'dep.mjs': 'let value=()=>42;export default value;value=()=>43',
    },
    read: 'ns.default()',
    expected: '42\n',
    guardReads: 1,
  },
  {
    name: 'default-alias',
    files: {
      'entry.mjs': "import{default as value}from'./dep.mjs';export default()=>value()",
      'dep.mjs': 'export default function value(){return 42}',
    },
    read: 'ns.default()',
    expected: '42\n',
    guardReads: 1,
  },
  {
    name: 'default-barrel',
    files: {
      'entry.mjs': "import value from'./dep.mjs';export default()=>value()",
      'dep.mjs': "export{default}from'./leaf.mjs'",
      'leaf.mjs': 'export default function value(){return 42}',
    },
    read: 'ns.default()',
    expected: '42\n',
    guardReads: 3,
  },
  {
    name: 'namespace-receiver',
    files: {
      'entry.mjs': "import*as values from'./dep.mjs';export default()=>values.value()",
      'dep.mjs': 'export const marker=42;export function value(){return this.marker}',
    },
    read: 'ns.default()',
    expected: '42\n',
    guardReads: 1,
  },
  {
    name: 'namespace-value',
    files: {
      'entry.mjs': "import*as values from'./dep.mjs';export default values",
      'dep.mjs': 'export function value(){return 42}',
    },
    read: 'ns.default.value()',
    expected: '42\n',
    guardReads: 1,
  },
  {
    name: 'namespace-live-export',
    files: {
      'entry.mjs':
        "import*as values from'./dep.mjs';export{values};export default()=>values.value()",
      'dep.mjs': 'export function value(){return 42}',
    },
    read: '[ns.values.value(),ns.default()]',
    expected: '[42,42]\n',
    guardReads: 1,
  },
  {
    name: 'bare-effect',
    files: {
      'entry.mjs': "import'./dep.mjs';export default globalThis.answer",
      'dep.mjs': 'globalThis.answer=42',
    },
    read: 'ns.default',
    expected: '42\n',
    guardReads: 1,
  },
  {
    name: 'bare-order',
    files: {
      'entry.mjs':
        "import'./first.mjs';import'./dep.mjs';export default globalThis.events.join(',')",
      'first.mjs': "globalThis.events=['a']",
      'dep.mjs': "globalThis.events.push('b')",
    },
    read: 'ns.default',
    expected: '"a,b"\n',
    guardReads: 2,
  },
  {
    name: 'mixed-live-lazy',
    files: {
      'entry.mjs':
        "import{left,right}from'./dep.mjs';export{left as live};export default()=>right()",
      'dep.mjs': 'export function left(){return 42}export function right(){return 42}',
    },
    read: '[ns.live(),ns.default()]',
    expected: '[42,42]\n',
    guardReads: 2,
  },
  {
    name: 'control-two-live-bindings-one-record',
    files: {
      'entry.mjs':
        "import{left,right}from'./dep.mjs';export{left,right};export default()=>left()+right()",
      'dep.mjs': 'export function left(){return 21}export function right(){return 21}',
    },
    read: '[ns.left(),ns.right(),ns.default()]',
    expected: '[21,21,42]\n',
    guardReads: 1,
  },
  {
    name: 'public-init-alias',
    files: {
      'entry.mjs':
        "import{value}from'./dep.mjs';export{value as init_entry};export default()=>value()",
      'dep.mjs': 'export function value(){return 42}',
    },
    read: '[ns.init_entry(),ns.default()]',
    expected: '[42,42]\n',
    guardReads: 1,
  },
  {
    name: 'public-namespace-alias',
    files: {
      'entry.mjs':
        "import{value}from'./dep.mjs';export{value as exports_entry};export default()=>value()",
      'dep.mjs': 'export function value(){return 42}',
    },
    read: '[ns.exports_entry(),ns.default()]',
    expected: '[42,42]\n',
    guardReads: 1,
  },
  {
    name: 'public-string-key',
    files: {
      'entry.mjs': `import{value}from'./dep.mjs';export{value as "x-y"};export default()=>value()`,
      'dep.mjs': 'export function value(){return 42}',
    },
    read: "[ns['x-y'](),ns.default()]",
    expected: '[42,42]\n',
    guardReads: 1,
  },
  {
    name: 'nested-namespace-decoy',
    files: {
      'entry.mjs':
        "import*as all from'./dep.mjs';export default function(exports_dep){return all.value()+exports_dep}",
      'dep.mjs': 'export function value(){return 42}',
    },
    read: 'ns.default(1)',
    expected: '43\n',
    guardReads: 1,
  },
  {
    name: 'namespace-tag-receiver',
    files: {
      'entry.mjs': "import*as all from'./dep.mjs';export default()=>all.tag`x`",
      'dep.mjs': 'export const marker=42;export function tag(){return this.marker}',
    },
    read: 'ns.default()',
    expected: '42\n',
    guardReads: 1,
  },
] as const;
const namespaceBarrels = [
  {
    name: 'named-function-live',
    leaf: 'export default function value(){return 42}export function change(){value=()=>43}',
    use: 'values.default()',
    expected: '43\n',
  },
  {
    name: 'expression-snapshot',
    leaf: 'let value=()=>42;export default value;export function change(){value=()=>43}',
    use: 'values.default()',
    expected: '42\n',
  },
  {
    name: 'member-snapshot',
    leaf: 'let value={member:()=>42};export default value.member;export function change(){value.member=()=>43}',
    use: 'values.default()',
    expected: '42\n',
  },
  {
    name: 'named-class-live',
    leaf: 'export default class Value{run(){return 42}}export function change(){Value=class{run(){return 43}}}',
    use: 'new values.default().run()',
    expected: '43\n',
  },
  {
    name: 'anonymous-class-snapshot',
    leaf: 'let value=class{run(){return 42}};export default class{run(){return 42}}export function change(){value=class{run(){return 43}}}',
    use: 'new values.default().run()',
    expected: '42\n',
  },
  {
    name: 'two-reexport-edges-live',
    leaf: 'export default function value(){return 42}export function change(){value=()=>43}',
    use: 'values.default()',
    expected: '43\n',
    chain: true,
  },
] as const;
const inputForms = [
  ...cases,
  ...namespaceBarrels.map((entry) => ({
    name: 'namespace-' + entry.name,
    files: {
      'entry.mjs': `import*as values from'./dep.mjs';import{helper}from'./other.mjs';export default function(){values.change();return ${entry.use}+helper()}`,
      'dep.mjs':
        'chain' in entry && entry.chain
          ? "export{default,change}from'./bridge.mjs'"
          : "export{default,change}from'./leaf.mjs'",
      'bridge.mjs': "export{default,change}from'./leaf.mjs'",
      'leaf.mjs': entry.leaf,
      'other.mjs': 'export function helper(){return 0}',
    },
    read: 'ns.default()',
    expected: entry.expected,
  })),
];
describe('native CLI plain preserved import initializers retain source values without a guard', () => {
  for (const entry of inputForms)
    for (const format of ['esm', 'cjs'] as const)
      for (const minify of [false, true])
        test(`${entry.name} ${format} minify=${minify}`, async () => {
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
            const expected = entry.expected;
            expect(native.status).toBe(0);
            expect(native.stderr).toBe('');
            expect(native.stdout).toBe(expected);
            const built = await execute(ZNTC_BIN, [
              '--bundle',
              join(dir, 'entry.mjs'),
              '--platform=react-native',
              '--format=' + format,
              '--output-exports=named',
              '--splitting',
              '--preserve-modules',
              '--preserve-modules-root=' + dir,
              '--outdir',
              join(dir, 'out'),
              ...(minify ? ['--minify'] : []),
            ]);
            expect(built.status).toBe(0);
            const file = join(dir, 'out/entry.js');
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
            expect(actual.stdout).toBe(native.stdout + '0' + String.fromCharCode(10));
          } finally {
            await cleanup();
          }
        });
});
