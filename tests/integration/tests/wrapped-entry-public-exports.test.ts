import { describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { build, close, init } from '../../../packages/core/index';
import { createFixture } from './helpers';
const cases = [
  ['anonymous-function', 'export default function(){return value();}', 42],
  ['named-function', 'export default function answer(){return value();}', 42],
  ['arrow', 'export default ()=>value();', 42],
  ['anonymous-class', 'export default class{run(){return value();}}', 42],
  ['named-class', 'export default class Box{run(){return value();}}', 42],
  ['object', 'export default {n:42};', 42],
  ['array', 'export default [42];', 42],
  ['literal', 'export default 42;', 42],
  ['expression-call', 'export default value();', 42],
  ['local-constant', 'const answer=42;export default answer;', 42],
] as const;
describe('wrapped ESM entry public exports keep their canonical local bindings', () => {
  for (const [name, body, expected] of cases)
    for (const mode of ['plain', 'identifiers-syntax', 'whitespace'] as const) {
      test(`${name}, ${mode}`, async () => {
        const fixture = await createFixture({
          'package.json': '{"type":"module"}',
          'entry.mjs': `import{value}from'./dep.mjs';${body}export const marker=7;export{marker as publicAlias};globalThis.entryValue=value;`,
          'second.mjs': 'import{value}from"./dep.mjs";globalThis.second=value;',
          'dep.mjs': 'export function value(){return 42;}',
        });
        try {
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
          const entry = pathToFileURL(join(dist, 'entry.js')).href;
          const script = `const ns=await import(${JSON.stringify(entry)});const d=ns.default;const actual=typeof d==='function'?(d.prototype?.run?new d().run():d()):Array.isArray(d)?d[0]:d?.n??d;console.log(JSON.stringify({keys:Object.keys(ns),actual,marker:ns.marker,alias:ns.publicAlias}));`;
          const run = spawnSync('node', ['--input-type=module', '-e', script], {
            encoding: 'utf8',
          });
          expect(run.status, run.stderr).toBe(0);
          expect(JSON.parse(run.stdout || '{}')).toEqual({
            keys: ['default', 'marker', 'publicAlias'],
            actual: expected,
            marker: 7,
            alias: 7,
          });
        } finally {
          close();
          await fixture.cleanup();
        }
      });
    }
});

const identifierDefaultSnapshotCases = [
  {
    name: 'local identifier',
    entry:
      "import{value}from'./dep.mjs';let state=value();export default state;export{state};state=value()+1;",
    second: "import{value}from'./dep.mjs';globalThis.second=value();",
    dependency: 'export function value(){return 42;}',
  },
  {
    name: 'imported identifier',
    entry: "import{state,update}from'./dep.mjs';export default state;export{state};update();",
    second: "import{state}from'./dep.mjs';globalThis.second=state;",
    dependency: 'export let state=42;export function update(){state=43;}',
  },
] as const;

describe('wrapped ESM entry identifier default expressions keep snapshot semantics', () => {
  for (const scenario of identifierDefaultSnapshotCases)
    for (const mode of ['plain', 'identifiers-syntax', 'whitespace'] as const) {
      test(`${scenario.name}, ${mode}`, async () => {
        const fixture = await createFixture({
          'package.json': '{"type":"module"}',
          'entry.mjs': scenario.entry,
          'second.mjs': scenario.second,
          'dep.mjs': scenario.dependency,
        });
        try {
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

          const runNamespace = (path: string) => {
            const script = `const ns=await import(${JSON.stringify(pathToFileURL(path).href)});console.log(JSON.stringify({default:ns.default,state:ns.state}));`;
            return spawnSync('node', ['--input-type=module', '-e', script], { encoding: 'utf8' });
          };
          const native = runNamespace(join(fixture.dir, 'entry.mjs'));
          const bundled = runNamespace(join(dist, 'entry.js'));
          expect(native.status, native.stderr).toBe(0);
          expect(bundled.status, bundled.stderr).toBe(0);
          expect(JSON.parse(native.stdout)).toEqual({ default: 42, state: 43 });
          expect(bundled.stdout).toBe(native.stdout);
        } finally {
          close();
          await fixture.cleanup();
        }
      });
    }
});

describe('wrapped ESM named default exports keep live binding semantics', () => {
  for (const mode of ['plain', 'identifiers-syntax', 'whitespace'] as const) {
    test(`export list default alias, ${mode}`, async () => {
      const fixture = await createFixture({
        'package.json': '{"type":"module"}',
        'entry.mjs':
          "import{value}from'./dep.mjs';let state=value();export{state as default,state};state=value()+1;",
        'second.mjs': "import{value}from'./dep.mjs';globalThis.second=value();",
        'dep.mjs': 'export function value(){return 42;}',
      });
      try {
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

        const runNamespace = (path: string) => {
          const script = `const ns=await import(${JSON.stringify(pathToFileURL(path).href)});console.log(JSON.stringify({default:ns.default,state:ns.state}));`;
          return spawnSync('node', ['--input-type=module', '-e', script], { encoding: 'utf8' });
        };
        const native = runNamespace(join(fixture.dir, 'entry.mjs'));
        const bundled = runNamespace(join(dist, 'entry.js'));
        expect(native.status, native.stderr).toBe(0);
        expect(bundled.status, bundled.stderr).toBe(0);
        expect(JSON.parse(native.stdout)).toEqual({ default: 43, state: 43 });
        expect(bundled.stdout).toBe(native.stdout);
      } finally {
        close();
        await fixture.cleanup();
      }
    });
  }
});
