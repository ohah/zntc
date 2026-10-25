import { describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

const inputs = [
  ['if without block', 'if(true) var shared=42;yield 0;return shared;'],
  [
    'for-of header and body',
    'for(var value of [42]){var shared=value;}yield 0;return[value,shared];',
  ],
  ['for header', 'for(var i=0;i<2;i++){var shared=40+i;}yield 0;return[shared,i];'],
  ['while', 'var i=0;while(i++<1){var shared=42;}yield 0;return shared;'],
  ['do-while', 'var i=0;do{var shared=42;}while(i++<0);yield 0;return shared;'],
  ['switch case', 'switch(1){case 1:var shared=42;break;}yield 0;return shared;'],
  [
    'try catch finally',
    'try{var shared=40;throw 2;}catch(e){shared+=e;var caught=7;}finally{var cleanup=9;}yield 0;return[shared,caught,cleanup];',
  ],
  ['object rest', 'if(true){var {x:shared,...rest}={x:42,y:7};}yield 0;return[shared,rest.y];'],
  ['for-of pattern', 'for(var {value:shared} of [{value:42}]){}yield 0;return shared;'],
  [
    'nested function and class boundaries',
    'if(true){var shared=42;function inner(){var shared=9;return shared;}class Box{static get(){var shared=7;return shared;}}var fn=inner;var klass=Box;}yield 0;return[shared,fn(),klass.get()];',
  ],
  ['no initializer redeclaration', 'var shared=42;if(true){var shared;}yield 0;return shared;'],
  [
    'lexical closure boundary',
    'if(true){let local=9;var get=()=>local;var shared=42;}yield 0;return[get(),shared];',
  ],
] as const;

describe('native generator var storage survives callback resumption (#4819)', () => {
  for (const [name, body] of inputs) {
    for (const target of ['es5', 'es2015', 'es2017']) {
      for (const minify of ['none', 'names', 'all']) {
        test(`${name}, target=${target}, minify=${minify}`, async () => {
          const fixture = await createFixture({
            'entry.mjs': `function* f(){${body}}const it=f();it.next();console.log(JSON.stringify(it.next().value));`,
          });
          try {
            const input = join(fixture.dir, 'entry.mjs');
            const native = spawnSync('node', [input], { encoding: 'utf8' });
            expect(native.status, native.stderr).toBe(0);
            expect(native.stdout.trim().length).toBeGreaterThan(0);
            const output = join(fixture.dir, 'out.mjs');
            const args = [input, `--target=${target}`, '-o', output];
            if (minify !== 'none') args.push('--minify-identifiers', '--minify-syntax');
            if (minify === 'all') args.push('--minify-whitespace');
            const built = spawnSync(ZNTC_BIN, args, { encoding: 'utf8' });
            expect(built.status, built.stderr).toBe(0);
            const transformed = spawnSync('node', [output], { encoding: 'utf8' });
            expect(transformed.status, transformed.stderr).toBe(0);
            expect(transformed.stdout).toBe(native.stdout);
          } finally {
            await fixture.cleanup();
          }
        });
      }
    }
  }
});

describe('native generator var storage in bundle module graphs (#4819)', () => {
  for (const [name, body] of inputs) {
    for (const format of ['esm', 'cjs']) {
      for (const split of [false, true]) {
        for (const minify of [false, true]) {
          test(`${name}, format=${format}, split=${split}, minify=${minify}`, async () => {
            const entry =
              'import {f} from "./factory.mjs";const it=f();it.next();console.log(JSON.stringify(it.next().value));';
            const fixture = await createFixture({
              'package.json': JSON.stringify({ type: format === 'cjs' ? 'commonjs' : 'module' }),
              'factory.mjs': `export function* f(){${body}}`,
              'entry.mjs': entry,
              'second.mjs': entry,
            });
            try {
              const source = join(fixture.dir, 'entry.mjs');
              const native = spawnSync('node', [source], { encoding: 'utf8' });
              expect(native.status, native.stderr).toBe(0);
              const output = join(
                fixture.dir,
                split ? 'dist/entry.js' : format === 'cjs' ? 'out.cjs' : 'out.mjs',
              );
              const args = ['--bundle', source, '--target=es5', `--format=${format}`];
              if (split)
                args.push(
                  join(fixture.dir, 'second.mjs'),
                  '--splitting',
                  '--outdir',
                  join(fixture.dir, 'dist'),
                );
              else args.push('-o', output);
              if (minify) args.push('--minify-identifiers', '--minify-syntax');
              const built = spawnSync(ZNTC_BIN, args, { encoding: 'utf8' });
              expect(built.status, built.stderr).toBe(0);
              const run = spawnSync('node', [output], { encoding: 'utf8' });
              expect(run.status, run.stderr).toBe(0);
              expect(run.stdout).toBe(native.stdout);
            } finally {
              await fixture.cleanup();
            }
          });
        }
      }
    }
  }
});

describe('native generator var storage preserves sloppy with lookup', () => {
  const controls = [
    'const host={shared:1};with(host){var shared=42;}yield 0;return [shared,host.shared];',
    'const host={shared:1};if(true){with(host){var shared=42;}}yield 0;return [shared,host.shared];',
    'var shared=7;const host={shared:1};with(host){var shared=42;}yield 0;return [shared,host.shared];',
    'const host={shared:1};with(host){var shared=42;var get=()=>shared;}yield 0;return [shared,get(),host.shared];',
  ];
  for (const [index, body] of controls.entries()) {
    for (const minify of [false, true]) {
      test(`with control=${index}, minify=${minify}`, async () => {
        const fixture = await createFixture({
          'entry.cjs': `function* run(){${body}}const it=run();it.next();console.log(JSON.stringify(it.next().value));`,
        });
        try {
          const input = join(fixture.dir, 'entry.cjs');
          const native = spawnSync('node', [input], { encoding: 'utf8' });
          expect(native.status, native.stderr).toBe(0);
          const output = join(fixture.dir, 'out.cjs');
          const args = [input, '--target=es5', '-o', output];
          if (minify) args.push('--minify-identifiers', '--minify-syntax');
          const built = spawnSync(ZNTC_BIN, args, { encoding: 'utf8' });
          expect(built.status, built.stderr).toBe(0);
          const run = spawnSync('node', [output], { encoding: 'utf8' });
          expect(run.status, run.stderr).toBe(0);
          expect(run.stdout).toBe(native.stdout);
        } finally {
          await fixture.cleanup();
        }
      });
    }
  }
});
