import { describe, expect, test } from 'bun:test';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';
import { build, close, init } from '../../../packages/core/index';
import { createFixture } from './helpers';

// Original ten-source corpus: SHA-256 0cd1b1bc1020ba3f05e97c6fb9bd39c7dc1ae655daa8161e69f1c5b9e4e3c5ef.
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

describe('preserved CJS eager imports use actual source Scope0 callers', () => {
  for (const entry of cases)
    for (const minify of [false, true]) {
      test(`${entry.name} minify=${minify}`, async () => {
        const { dir, cleanup } = await createFixture({
          'package.json': '{"type":"commonjs"}',
          ...entry.files,
        });
        try {
          const execute = (file: string, guarded: boolean) =>
            spawnSync(
              'node',
              [
                '--input-type=module',
                '-e',
                `${guarded ? "let reads=0;Object.defineProperty(globalThis,'ErrorUtils',{configurable:true,get(){reads++;return undefined}});" : ''}const ns=${JSON.stringify(file)}.endsWith('.mjs')?await import(${JSON.stringify(pathToFileURL(file).href)}):(await import('node:module')).createRequire(import.meta.url)(${JSON.stringify(file)});${guarded ? "const descriptor=Object.getOwnPropertyDescriptor(ns,'default');if(!descriptor||!descriptor.enumerable||typeof descriptor.get!=='function')throw new Error('missing public getter');const marker=Object.getOwnPropertyDescriptor(ns,'__esModule');if(!marker||marker.value!==true||marker.enumerable)throw new Error('missing interop marker');const babel=ns&&ns.__esModule?ns:{default:ns};if(babel.default!==ns.default)throw new Error('wrong interop default');" : ''}console.log(JSON.stringify(${entry.read}));${guarded ? 'console.log(reads);' : ''}`,
              ],
              { encoding: 'utf8' },
            );
          const native = execute(join(dir, 'entry.mjs'), false);
          expect(native.status).toBe(0);
          expect(native.stderr).toBe('');
          expect(native.stdout).toBe(entry.expected);
          await init();
          try {
            const result = await build({
              entryPoints: [join(dir, 'entry.mjs')],
              rootDir: dir,
              outdir: join(dir, 'out'),
              write: true,
              platform: 'react-native',
              format: 'cjs',
              outputExports: 'named',
              splitting: true,
              preserveModules: true,
              minify,
            });
            expect(result.errors).toEqual([]);
          } finally {
            close();
          }
          const actual = execute(join(dir, 'out/entry.js'), true);
          expect(actual.status).toBe(0);
          expect(actual.stderr).toBe('');
          expect(actual.stdout).toBe(`${native.stdout}${entry.guardReads}\n`);
        } finally {
          await cleanup();
        }
      });
    }
});

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

describe('owned namespace reexports preserve source default roles', () => {
  for (const entry of namespaceBarrels)
    for (const minify of [false, true]) {
      test(`${entry.name} minify=${minify}`, async () => {
        const chain = 'chain' in entry && entry.chain;
        const { dir, cleanup } = await createFixture({
          'package.json': '{"type":"commonjs"}',
          'entry.mjs': `import*as values from'./dep.mjs';import{helper}from'./other.mjs';export default function(){values.change();return ${entry.use}+helper()}`,
          'dep.mjs': chain
            ? "export{default,change}from'./bridge.mjs'"
            : "export{default,change}from'./leaf.mjs'",
          'bridge.mjs': "export{default,change}from'./leaf.mjs'",
          'leaf.mjs': entry.leaf,
          'other.mjs': 'export function helper(){return 0}',
        });
        try {
          const execute = (file: string) =>
            spawnSync(
              'node',
              [
                '--input-type=module',
                '-e',
                `const ns=${JSON.stringify(file)}.endsWith('.mjs')?await import(${JSON.stringify(pathToFileURL(file).href)}):(await import('node:module')).createRequire(import.meta.url)(${JSON.stringify(file)});console.log(ns.default());`,
              ],
              { encoding: 'utf8' },
            );
          const native = execute(join(dir, 'entry.mjs'));
          expect(native.status).toBe(0);
          expect(native.stderr).toBe('');
          expect(native.stdout).toBe(entry.expected);
          await init();
          try {
            const result = await build({
              entryPoints: [join(dir, 'entry.mjs')],
              rootDir: dir,
              outdir: join(dir, 'out'),
              write: true,
              platform: 'react-native',
              format: 'cjs',
              outputExports: 'named',
              splitting: true,
              preserveModules: true,
              minify,
            });
            expect(result.errors).toEqual([]);
          } finally {
            close();
          }
          const actual = execute(join(dir, 'out/entry.js'));
          expect(actual.status).toBe(0);
          expect(actual.stderr).toBe('');
          expect(actual.stdout).toBe(native.stdout);
        } finally {
          await cleanup();
        }
      });
    }
});

describe('preserved CJS public default getters keep native source roles', () => {
  for (const entry of namespaceBarrels)
    for (const minify of [false, true])
      test(`${entry.name} minify=${minify}`, async () => {
        const chain = 'chain' in entry && entry.chain;
        const { dir, cleanup } = await createFixture({
          'package.json': '{"type":"commonjs"}',
          'entry.mjs': chain ? "export{default,change}from'./leaf.mjs'" : entry.leaf,
          'leaf.mjs': entry.leaf,
        });
        try {
          const execute = (file: string) =>
            spawnSync(
              'node',
              [
                '--input-type=module',
                '-e',
                `const values=${JSON.stringify(file)}.endsWith('.mjs')?await import(${JSON.stringify(pathToFileURL(file).href)}):(await import('node:module')).createRequire(import.meta.url)(${JSON.stringify(file)});values.change();console.log(${entry.use});`,
              ],
              { encoding: 'utf8' },
            );
          const native = execute(join(dir, 'entry.mjs'));
          expect(native.status).toBe(0);
          expect(native.stdout).toBe(entry.expected);
          await init();
          try {
            const result = await build({
              entryPoints: [join(dir, 'entry.mjs')],
              rootDir: dir,
              outdir: join(dir, 'out'),
              write: true,
              platform: 'react-native',
              format: 'cjs',
              outputExports: 'named',
              splitting: true,
              preserveModules: true,
              minify,
            });
            expect(result.errors).toEqual([]);
          } finally {
            close();
          }
          const actual = execute(join(dir, 'out/entry.js'));
          expect(actual.status).toBe(0);
          expect(actual.stderr).toBe('');
          expect(actual.stdout).toBe(native.stdout);
        } finally {
          await cleanup();
        }
      });
});

describe('preserved CJS source public interop-name exports keep their actual getter', () => {
  for (const alias of ['__esModule', '"__esModule"', '"\\u005f_esModule"'])
    for (const minify of [false, true])
      test(`${alias} minify=${minify}`, async () => {
        const { dir, cleanup } = await createFixture({
          'package.json': '{"type":"commonjs"}',
          'entry.mjs': `const marker=0;export{marker as ${alias}};export default function(){return 42}`,
        });
        try {
          const execute = (file: string) =>
            spawnSync(
              'node',
              [
                '--input-type=module',
                '-e',
                `const ns=${JSON.stringify(file)}.endsWith('.mjs')?await import(${JSON.stringify(pathToFileURL(file).href)}):(await import('node:module')).createRequire(import.meta.url)(${JSON.stringify(file)});console.log(JSON.stringify([ns.default(),ns.__esModule]));`,
              ],
              { encoding: 'utf8' },
            );
          const native = execute(join(dir, 'entry.mjs'));
          expect(native.status).toBe(0);
          expect(native.stdout).toBe('[42,0]\n');
          await init();
          try {
            const result = await build({
              entryPoints: [join(dir, 'entry.mjs')],
              rootDir: dir,
              outdir: join(dir, 'out'),
              write: true,
              platform: 'react-native',
              format: 'cjs',
              outputExports: 'named',
              splitting: true,
              preserveModules: true,
              minify,
            });
            expect(result.errors).toEqual([]);
          } finally {
            close();
          }
          const actual = execute(join(dir, 'out/entry.js'));
          expect(actual.status).toBe(0);
          expect(actual.stderr).toBe('');
          expect(actual.stdout).toBe(native.stdout);
        } finally {
          await cleanup();
        }
      });
});
