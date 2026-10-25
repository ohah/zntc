import { describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { build, close, init } from '../../../packages/core/index';
import { createFixture } from './helpers';

const cases = [
  ['class method', 'class Box{run(){return value();}}events.push(new Box().run());', [42]],
  [
    'class expression',
    'const Box=class{run(){return value();}};events.push(new Box().run());',
    [42],
  ],
  [
    'computed key',
    'class Box{[value()](){}}events.push(Object.getOwnPropertyNames(Box.prototype).includes("42"));',
    [true],
  ],
  [
    'derived class',
    'class Base{run(){return value();}}class Box extends Base{}events.push(new Box().run());',
    [42],
  ],
  ['static method', 'class Box{static run(){return value();}}events.push(Box.run());', [42]],
  ['constructor', 'class Box{constructor(){this.n=value();}}events.push(new Box().n);', [42]],
  ['getter', 'class Box{get n(){return value();}}events.push(new Box().n);', [42]],
  [
    'setter',
    'class Box{set n(x){this.actual=x;}}const box=new Box();box.n=value();events.push(box.actual);',
    [42],
  ],
  ['class field', 'class Box{n=value();}events.push(new Box().n);', [42]],
  ['generator', 'function* sequence(){yield value();}events.push(sequence().next().value);', [42]],
  [
    'capture before source mutation',
    'class Box{run(){return value();}}events.push("entry",new Box().run());Object.defineProperty(globalThis,"global",{configurable:true,get(){events.push("late-global");return globalThis;}});',
    ['entry', 42],
  ],
] as const;

describe('unwrapped source helper initializers use their actual guard provider', () => {
  for (const [name, body, expected] of cases) {
    for (const format of ['esm', 'cjs'] as const) {
      for (const mode of ['plain', 'identifiers-syntax', 'whitespace'] as const) {
        test(`${name}, ${format}, ${mode}`, async () => {
          const fixture = await createFixture({
            'package.json': '{"type":"module","sideEffects":false}',
            'entry.mjs': `import{value}from'./dep.mjs';${body}`,
            'second.mjs': 'import{value}from"./dep.mjs";globalThis.second=value;',
            'dep.mjs': 'export function value(){return 42;}',
          });
          try {
            await init();
            const dist = join(fixture.dir, 'dist');
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
            const execution = spawnSync(
              'node',
              [
                '--input-type=module',
                '-e',
                `globalThis.events=[];await import(${JSON.stringify(entry)});console.log(JSON.stringify(events));`,
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
    }
  }
});
