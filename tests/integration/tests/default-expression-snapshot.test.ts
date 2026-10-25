import { describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { writeFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { build, close, init, transpile } from '../../../packages/core/index';
import { createFixture } from './helpers';

const cases = [
  ['let', 'let value=42;export default value;export function change(){value=43;}', 42],
  ['var', 'var value=42;export default value;export function change(){value=43;}', 42],
  [
    'facade-name',
    'let _default=42;export default _default;export function change(){_default=43;}',
    42,
  ],
  ['escaped', 'let v\\u0061lue=42;export default value;export function change(){value=43;}', 42],
  ['function', 'let value=()=>42;export default value;export function change(){value=()=>43;}', 42],
  [
    'class',
    'let value=class{run(){return 42;}};export default value;export function change(){value=class{run(){return 43;}};}',
    42,
  ],
  [
    'object-identity',
    'let value={n:42};export default value;export function change(){value.n=44;value={n:43};}',
    44,
  ],
  [
    'array-identity',
    'let value=[42];export default value;export function change(){value[0]=44;value=[43];}',
    44,
  ],
  [
    'imported-named',
    'import{value,change}from"./dep.mjs";export default value;export{change};',
    42,
  ],
  [
    'imported-default',
    'import value,{change}from"./dep.mjs";export default value;export{change};',
    42,
  ],
  [
    'imported-facade-name',
    'import{value as _default,change}from"./dep.mjs";export default _default;export{change};',
    42,
  ],
] as const;

const controls = [
  [
    'live-alias',
    'let value=42;export{value as default};export function change(){value=43;}',
    43,
    false,
  ],
  [
    'named-function-declaration',
    'export default function value(){return 42;}export function change(){value=function replacement(){return 43;};}',
    43,
    false,
  ],
  [
    'named-class-declaration',
    'export default class Value{run(){return 42;}}export function change(){Value=class{run(){return 43;}};}',
    43,
    false,
  ],
  [
    'unresolved-global',
    'globalThis._default=42;export default _default;export function change(){globalThis._default=43;}',
    42,
    true,
  ],
  [
    'escaped-global',
    'globalThis._default=42;export default \\u005fdefault;export function change(){globalThis._default=43;}',
    42,
    true,
  ],
] as const;
const allCases = [
  ...cases.map(([name, source, after]) => [name, source, after, true] as const),
  ...controls,
];

function run(file: string) {
  const script = `const ns=await import(${JSON.stringify(pathToFileURL(file).href)});const read=()=>{const d=ns.default;return typeof d==='function'?(d.prototype?.run?new d().run():d()):Array.isArray(d)?d[0]:d?.n??d;};const initial=ns.default;const before=read();ns.change();console.log(JSON.stringify({before,after:read(),same:initial===ns.default}));`;
  return spawnSync('node', ['--input-type=module', '-e', script], { encoding: 'utf8' });
}

describe('default identifier expressions capture a value without replacing the source binding', () => {
  for (const [name, source, after, same] of allCases)
    for (const mode of ['plain', 'identifiers-syntax', 'whitespace'] as const) {
      test(`${name}, ${mode}`, async () => {
        const fixture = await createFixture({
          'package.json': '{"type":"module"}',
          'entry.mjs': `import{helper}from'./shared.mjs';${source}globalThis.entryValue=helper;`,
          'second.mjs': 'import{helper}from"./shared.mjs";globalThis.second=helper;',
          'shared.mjs': 'export function helper(){return 42;}',
          'dep.mjs':
            'let value=42;export{value,value as default};export function change(){value=43;}',
        });
        try {
          const native = run(join(fixture.dir, 'entry.mjs'));
          expect(native.status, native.stderr).toBe(0);
          const expected = { before: 42, after, same };
          expect(JSON.parse(native.stdout)).toEqual(expected);
          await init();
          const dist = join(fixture.dir, 'dist');
          const result = await build({
            entryPoints: [join(fixture.dir, 'entry.mjs'), join(fixture.dir, 'second.mjs')],
            rootDir: fixture.dir,
            outdir: dist,
            write: true,
            platform: 'react-native',
            format: 'esm',
            splitting: true,
            minifyIdentifiers: mode !== 'plain',
            minifySyntax: mode !== 'plain',
            minifyWhitespace: mode === 'whitespace',
          });
          expect(result.errors ?? []).toHaveLength(0);
          const actual = run(join(dist, 'entry.js'));
          expect(actual.status, actual.stderr).toBe(0);
          expect(JSON.parse(actual.stdout || '{}')).toEqual(expected);
        } finally {
          close();
          await fixture.cleanup();
        }
      });
    }
});

describe('named default declarations stay live through standalone lowering', () => {
  const sources = [
    [
      'class',
      'export default class Value{run(){return 42;}}export function change(){Value=class{run(){return 43;}};}',
    ],
    [
      'function',
      'export default function value(){return 42;}export function change(){value=function(){return 43;};}',
    ],
  ] as const;
  for (const [name, source] of sources)
    for (const target of ['es5', 'es2017', 'es2022'] as const)
      for (const minify of [false, true]) {
        test(`${name}, ${target}, minify=${minify}`, async () => {
          const fixture = await createFixture({ 'entry.mjs': source });
          try {
            const native = run(join(fixture.dir, 'entry.mjs'));
            expect(native.status, native.stderr).toBe(0);
            const expected = { before: 42, after: 43, same: false };
            expect(JSON.parse(native.stdout)).toEqual(expected);
            const result = transpile(source, {
              filename: 'entry.mjs',
              target,
              minifyIdentifiers: minify,
              minifySyntax: minify,
              minifyWhitespace: minify,
            });
            const output = join(fixture.dir, 'output.mjs');
            await writeFile(output, result.code);
            const actual = run(output);
            expect(actual.status, actual.stderr).toBe(0);
            expect(JSON.parse(actual.stdout || '{}')).toEqual(expected);
          } finally {
            await fixture.cleanup();
          }
        });
      }
});

const namedClassCases = [
  ['basic', 'export default class Value{run(){return 42;}}', 'Value'],
  ['extends', 'export default class Value extends class{}{run(){return 42;}}', 'Value'],
  ['static-field', 'export default class Value{static seed=42;run(){return Value.seed;}}', 'Value'],
  ['private-field', 'export default class Value{#seed=42;run(){return this.#seed;}}', 'Value'],
  ['computed-key', "const label='run';export default class Value{[label](){return 42;}}", 'Value'],
  [
    'constructor-default',
    'export default class Value{constructor(seed=42){this.seed=seed;}run(){return this.seed;}}',
    'Value',
  ],
  ['method-shadow', 'export default class Value{run(){const Value=42;return Value;}}', 'Value'],
  ['facade-name', 'export default class _default{run(){return 42;}}', '_default'],
  ['escaped-name', String.raw`export default class V\u0061lue{run(){return 42;}}`, 'Value'],
  [
    'static-block',
    'export default class Value{static{this.seed=42;}run(){return Value.seed;}}',
    'Value',
  ],
] as const;

describe('ten named class declaration producers preserve live default bindings', () => {
  for (const [name, declaration, binding] of namedClassCases) {
    const source = `${declaration}export function change(){${binding}=class{run(){return 43;}};}`;
    for (const mode of ['plain', 'identifiers-syntax', 'whitespace'] as const) {
      test(`bundle ${name}, ${mode}`, async () => {
        const fixture = await createFixture({
          'package.json': '{"type":"module"}',
          'entry.mjs': `import{helper}from'./shared.mjs';${source}globalThis.entryValue=helper;`,
          'second.mjs': 'import{helper}from"./shared.mjs";globalThis.second=helper;',
          'shared.mjs': 'export function helper(){return 42;}',
        });
        try {
          const expected = { before: 42, after: 43, same: false };
          const native = run(join(fixture.dir, 'entry.mjs'));
          expect(native.status, native.stderr).toBe(0);
          expect(JSON.parse(native.stdout)).toEqual(expected);
          await init();
          const dist = join(fixture.dir, 'dist');
          const result = await build({
            entryPoints: [join(fixture.dir, 'entry.mjs'), join(fixture.dir, 'second.mjs')],
            rootDir: fixture.dir,
            outdir: dist,
            write: true,
            platform: 'react-native',
            format: 'esm',
            splitting: true,
            minifyIdentifiers: mode !== 'plain',
            minifySyntax: mode !== 'plain',
            minifyWhitespace: mode === 'whitespace',
          });
          expect(result.errors ?? []).toHaveLength(0);
          const actual = run(join(dist, 'entry.js'));
          expect(actual.status, actual.stderr).toBe(0);
          expect(JSON.parse(actual.stdout || '{}')).toEqual(expected);
        } finally {
          close();
          await fixture.cleanup();
        }
      });
    }
    for (const minify of [false, true]) {
      test(`standalone ES5 ${name}, minify=${minify}`, async () => {
        const fixture = await createFixture({ 'entry.mjs': source });
        try {
          const expected = { before: 42, after: 43, same: false };
          const native = run(join(fixture.dir, 'entry.mjs'));
          expect(native.status, native.stderr).toBe(0);
          expect(JSON.parse(native.stdout)).toEqual(expected);
          const result = transpile(source, {
            filename: 'entry.mjs',
            target: 'es5',
            minifyIdentifiers: minify,
            minifySyntax: minify,
            minifyWhitespace: minify,
          });
          const output = join(fixture.dir, 'output.mjs');
          await writeFile(output, result.code);
          const actual = run(output);
          expect(actual.status, actual.stderr).toBe(0);
          expect(JSON.parse(actual.stdout || '{}')).toEqual(expected);
        } finally {
          await fixture.cleanup();
        }
      });
    }
  }
});
