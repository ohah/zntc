import { describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { build, close, init } from '../../../packages/core/index';
import { createFixture } from './helpers';
const cases = [
  [
    'returned-function',
    'function run(__zntc_guarded){return value;}events.push(run(null)());',
    [42],
  ],
  [
    'typeof',
    'function run(__zntc_guarded){return typeof value;}events.push(run(null));',
    ['function'],
  ],
  [
    'shorthand',
    'function run(__zntc_guarded){return {value};}events.push(run(null).value());',
    [42],
    'globalThis.__guardValueReady=true;export function value(){return globalThis.__guardValueReady?42:-1;}',
  ],
  ['array', 'function run(__zntc_guarded){return [value];}events.push(run(null)[0]());', [42]],
  [
    'spread',
    'function run(__zntc_guarded){return [...value];}events.push(run(null)[0]);',
    [42],
    'export const value=[42];',
  ],
  [
    'constructor',
    'function run(__zntc_guarded){return new value() instanceof value;}events.push(run(null));',
    [true],
  ],
  ['tag', 'function run(__zntc_guarded){return value`text`;}events.push(run(null));', [42]],
  [
    'call-property',
    'function run(__zntc_guarded){return value.call(undefined);}events.push(run(null));',
    [42],
  ],
  ['optional-call', 'function run(__zntc_guarded){return value?.();}events.push(run(null));', [42]],
  [
    'object-receiver',
    'function run(__zntc_guarded){return value.run();}events.push(run(null));',
    [true],
    'export const value={run(){return this===value;}};',
  ],
  [
    'strict returned receiver',
    'function run(__zntc_guarded){return value;}events.push(run(null)());',
    [true],
    "export function value(){'use strict';return this===undefined;}",
  ],
  [
    'strict tag receiver',
    'function run(__zntc_guarded){return value`text`;}events.push(run(null));',
    [true],
    "export function value(){'use strict';return this===undefined;}",
  ],
  [
    'getter receiver once',
    'function run(__zntc_guarded){return value.run();}events.push(run(null));',
    [[1, true]],
    'let reads=0;export const value={get run(){reads++;return function(){return[reads,this===value];}}};',
  ],
  [
    'constructor argument order',
    'function run(__zntc_guarded){return new value((events.push("argument"),42)).n;}events.push(run(null));',
    ['initialize', 'argument', 'construct', 42],
    'events.push("initialize");export function value(n){events.push("construct");this.n=n;}',
  ],
  [
    'tag substitution order',
    'function run(__zntc_guarded){return value`${(events.push("substitution"),42)}`;}events.push(run(null));',
    ['initialize', 'substitution', 'tag', 42],
    'events.push("initialize");export function value(parts,arg){events.push("tag");return arg;}',
  ],
  [
    'conditional separate reads',
    'function run(__zntc_guarded,choose){return choose?value:value;}events.push(run(null,false).n);',
    [42],
    'export const value={n:42};',
  ],
  [
    'multiple read identity',
    'function run(__zntc_guarded){return [value,value];}const pair=run(null);events.push([pair[0]===pair[1],pair[0].n,globalThis.initializations]);',
    [[true, 42, 1]],
    'globalThis.initializations=(globalThis.initializations||0)+1;export const value={n:42};',
  ],
  [
    'guard import alias decoy',
    'function run(__import_callsite_0){return value;}events.push(run(null)());',
    [42],
  ],
  [
    'initializer import alias decoy',
    'function run(__import_callsite_1){return value;}events.push(run(null)());',
    [42],
  ],
  [
    'late returned function',
    'globalThis.load=function(__zntc_guarded){return value;};',
    ['report:dependency', 42],
    'throw new Error("dependency");export function value(){return 42;}',
  ],
] as const;
describe('guarded imported values retain evaluation order and receivers', () => {
  for (const [name, body, expected, dependency] of cases)
    for (const format of ['esm', 'cjs'] as const)
      for (const mode of ['plain', 'identifiers-syntax', 'whitespace'] as const) {
        test(`${name}, ${format}, ${mode}`, async () => {
          const fixture = await createFixture({
            'package.json': '{"type":"module"}',
            'entry.mjs': `import{value}from'./dep.mjs';${body}`,
            'second.mjs': 'import{value}from"./dep.mjs";globalThis.second=value;',
            'dep.mjs': dependency ?? 'export function value(){return 42;}',
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
              format,
              splitting: true,
              minifyIdentifiers: mode !== 'plain',
              minifySyntax: mode !== 'plain',
              minifyWhitespace: mode === 'whitespace',
              outExtension: format === 'cjs' ? '.cjs' : undefined,
            });
            expect(result.errors ?? []).toHaveLength(0);
            const entry = pathToFileURL(
              join(dist, format === 'cjs' ? 'entry.cjs' : 'entry.js'),
            ).href;
            const late = name === 'late returned function';
            const before = late
              ? 'globalThis.ErrorUtils={reportFatalError(e){events.push("report:"+e.message);}};'
              : '';
            const after = late ? 'events.push(globalThis.load(null)());' : '';
            const execution = spawnSync(
              'node',
              [
                '--input-type=module',
                '-e',
                `globalThis.events=[];${before}await import(${JSON.stringify(entry)});${after}console.log(JSON.stringify(events));`,
              ],
              { encoding: 'utf8' },
            );
            expect(execution.status, execution.stderr).toBe(0);
            expect(execution.stdout.trim()).toBe(JSON.stringify(expected));
          } finally {
            close();
            await fixture.cleanup();
          }
        });
      }
});
