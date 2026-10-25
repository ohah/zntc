import { describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { build, close, init } from '../../../packages/core/index';
import { createFixture } from './helpers';

const cases = [
  [
    'function parameter',
    'function run(__zntc_guarded){return value();}events.push(run(null));',
    [42],
  ],
  ['arrow parameter', 'const run=(__zntc_guarded)=>value();events.push(run(null));', [42]],
  [
    'method parameter',
    'class Box{run(__zntc_guarded){return value();}}events.push(new Box().run(null));',
    [42],
  ],
  ['catch binding', 'try{throw null;}catch(__zntc_guarded){events.push(value());}', [42]],
  ['block binding', '{let __zntc_guarded=null;events.push(value());}', [42]],
  [
    'function var',
    'function run(){var __zntc_guarded=null;return value();}events.push(run());',
    [42],
  ],
  [
    'parameter initializer',
    'function run(__zntc_guarded=null,result=value()){return result;}events.push(run());',
    [42],
  ],
  [
    'computed key',
    'function run(__zntc_guarded){return class{[value()](){}};}events.push(Object.getOwnPropertyNames(run(null).prototype).includes("42"));',
    [true],
  ],
  [
    'generator parameter',
    'function* run(__zntc_guarded){yield value();}events.push(run(null).next().value);',
    [42],
  ],
  [
    'nested closure',
    'function run(__zntc_guarded){return (()=>value())();}events.push(run(null));',
    [42],
  ],
  [
    'argument order',
    'function run(__zntc_guarded){return value((events.push("argument"),1));}events.push(run(null));',
    ['initialize', 'argument', 42],
    'events.push("initialize");export function value(n){return 41+n;}',
  ],
  [
    'late initialization reporter',
    'globalThis.load=function(){return value();};',
    ['report:dependency', 42],
    'throw new Error("dependency");export function value(){return 42;}',
  ],
] as const;

describe('guarded lazy imports use their actual source scope', () => {
  for (const [name, body, expected, dependency] of cases) {
    for (const format of ['esm', 'cjs'] as const) {
      for (const mode of ['plain', 'identifiers-syntax', 'whitespace'] as const) {
        test(`${name}, ${format}, ${mode}`, async () => {
          const fixture = await createFixture({
            'package.json': '{"type":"module"}',
            'entry.mjs': `import{value}from'./dep.mjs';${body}`,
            'second.mjs': 'import{value}from"./dep.mjs";globalThis.second=value;',
            'dep.mjs': dependency ?? 'export function value(){return 42;}',
          });
          try {
            const dist = join(fixture.dir, 'dist');
            await init();
            const output = await build({
              entryPoints: [join(fixture.dir, 'entry.mjs'), join(fixture.dir, 'second.mjs')],
              rootDir: fixture.dir,
              outdir: dist,
              write: true,
              platform: 'react-native',
              format,
              splitting: true,
              minifyIdentifiers: mode !== 'plain',
              minifySyntax: mode !== 'plain',
              minifyWhitespace: mode === 'whitespace',
              outExtension: format === 'cjs' ? '.cjs' : undefined,
            });
            expect(output.errors ?? []).toHaveLength(0);
            const entry = pathToFileURL(
              join(dist, format === 'cjs' ? 'entry.cjs' : 'entry.js'),
            ).href;
            const reporter =
              name === 'late initialization reporter'
                ? 'globalThis.ErrorUtils={reportFatalError(e){events.push("report:"+e.message);}};'
                : '';
            const after =
              name === 'late initialization reporter'
                ? 'try{events.push(globalThis.load());}catch(e){events.push(e instanceof TypeError?"type-error":e.message);}'
                : '';
            const run = spawnSync(
              'node',
              [
                '--input-type=module',
                '-e',
                `globalThis.events=[];${reporter}try{await import(${JSON.stringify(entry)});${after}}catch(e){events.push("throw:"+e.message);}console.log(JSON.stringify(events));`,
              ],
              { encoding: 'utf8' },
            );
            expect(run.status, run.stderr).toBe(0);
            expect(run.stdout.trim()).toBe(JSON.stringify(expected));
          } finally {
            close();
            await fixture.cleanup();
          }
        });
      }
    }
  }
});
