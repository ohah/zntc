import { describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { build, close, init } from '../../../packages/core/index';
import { createFixture } from './helpers';

const defaults = [
  ['anonymous function', 'function(){return run(null);}'],
  ['arrow', '()=>run(null)'],
  ['anonymous class', 'class{method(){return run(null);}}'],
  ['object', '{run}'],
  ['array', '[run]'],
  ['call', 'Object.freeze({run})'],
  ['conditional', 'globalThis.choose?run:null'],
  ['sequence', '(0,run)'],
  ['literal', '42'],
  ['helper initialization', '{run,sequence}'],
] as const;

describe('guarded source default facades retain executable source behavior', () => {
  for (const [name, value] of defaults) {
    for (const format of ['esm', 'cjs'] as const) {
      for (const mode of ['plain', 'identifiers-syntax', 'whitespace'] as const) {
        test(`${name}, ${format}, ${mode}`, async () => {
          const helper = name === 'helper initialization';
          const fixture = await createFixture({
            'package.json': '{"type":"module"}',
            'entry.mjs': `import{value}from'./dep.mjs';function run(__zntc_guarded){return value();}${helper ? 'function* sequence(){yield 0;}' : ''}export default ${value};events.push(run(null));${helper ? 'events.push(sequence().next().value);' : ''}`,
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
              splitting: true,
              format,
              minifyIdentifiers: mode !== 'plain',
              minifySyntax: mode !== 'plain',
              minifyWhitespace: mode === 'whitespace',
              outExtension: format === 'cjs' ? '.cjs' : undefined,
            });
            expect(result.errors ?? []).toHaveLength(0);
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
            expect(execution.stdout.trim()).toBe(JSON.stringify(helper ? [42, 0] : [42]));
          } finally {
            close();
            await fixture.cleanup();
          }
        });
      }
    }
  }
});
