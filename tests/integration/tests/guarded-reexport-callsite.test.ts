import { describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { build, close, init } from '../../../packages/core/index';
import { createFixture } from './helpers';
const cases = [
  ['const', 'export const answer=42;', 'export{answer as default}from"./other.mjs";'],
  ['let', 'export let answer=42;', 'export{answer as default}from"./other.mjs";'],
  ['var', 'export var answer=42;', 'export{answer as default}from"./other.mjs";'],
  [
    'function',
    'export function answer(){return 42;}',
    'export{answer as default}from"./other.mjs";',
  ],
  [
    'class',
    'export class answer{run(){return 42;}}',
    'export{answer as default}from"./other.mjs";',
  ],
  ['object', 'export const answer={n:42};', 'export{answer as default}from"./other.mjs";'],
  ['array', 'export const answer=[42];', 'export{answer as default}from"./other.mjs";'],
  [
    'call-expression',
    'export const answer=(()=>42)();',
    'export{answer as default}from"./other.mjs";',
  ],
  ['facade', 'export default 42;', 'export{default}from"./other.mjs";'],
  [
    'public-alias',
    'const answer=42;export{answer as renamed};',
    'export{renamed as default}from"./other.mjs";',
  ],
] as const;
describe('guarded reexport initializers use real Scope0 caller edges', () => {
  for (const [name, provider, body] of cases)
    for (const mode of ['plain', 'identifiers-syntax', 'whitespace'] as const) {
      test(`${name}, ${mode}`, async () => {
        const fixture = await createFixture({
          'package.json': '{"type":"module"}',
          'entry.mjs': `${body}export const marker=7;export{marker as publicAlias};globalThis.order.push('entry');`,
          'second.mjs': 'import{value}from"./dep.mjs";globalThis.second=value;',
          'dep.mjs': 'export function value(){return 42;}',
          'other.mjs': `globalThis.order=[];globalThis.order.push('other');${provider}`,
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
          const script = `const ns=await import(${JSON.stringify(entry)});const d=ns.default;const actual=typeof d==='function'?(d.prototype?.run?new d().run():d()):Array.isArray(d)?d[0]:d?.n??d;console.log(JSON.stringify({keys:Object.keys(ns),actual,marker:ns.marker,alias:ns.publicAlias,order:globalThis.order}));`;
          const run = spawnSync('node', ['--input-type=module', '-e', script], {
            encoding: 'utf8',
          });
          expect(run.status, run.stderr).toBe(0);
          expect(JSON.parse(run.stdout || '{}')).toEqual({
            keys: ['default', 'marker', 'publicAlias'],
            actual: 42,
            marker: 7,
            alias: 7,
            order: ['other', 'entry'],
          });
        } finally {
          close();
          await fixture.cleanup();
        }
      });
    }
});
