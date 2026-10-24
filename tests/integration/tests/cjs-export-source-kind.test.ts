import { describe, test, expect } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

const sources = [
  [
    'function module',
    'const out={};function set(module){module.exports=42;}set(out);const value=out.exports;',
  ],
  [
    'function exports',
    'const out={};function set(exports){exports.value=42;}set(out);const value=out.value;',
  ],
  [
    'arrow module',
    'const out={};const set=(module)=>{module.exports=42;};set(out);const value=out.exports;',
  ],
  [
    'arrow exports',
    'const out={};const set=(exports)=>{exports.value=42;};set(out);const value=out.value;',
  ],
  ['block module', 'let value;{const module={};module.exports=42;value=module.exports;}'],
  ['block exports', 'let value;{const exports={};exports.value=42;value=exports.value;}'],
  [
    'catch module',
    'let value;try{throw {};}catch(module){module.exports=42;value=module.exports;}',
  ],
  [
    'catch exports',
    'let value;try{throw {};}catch(exports){exports.value=42;value=exports.value;}',
  ],
  [
    'defineProperty module',
    'const out={};function set(module){Object.defineProperty(module,"exports",{value:42});}set(out);const value=out.exports;',
  ],
  [
    'defineProperty exports',
    'const out={};function set(exports){Object.defineProperty(exports,"value",{value:42});}set(out);const value=out.value;',
  ],
] as const;
const targets = ['--target=es5', '--target=es2017', '--platform=react-native'];

describe('CJS export source kind follows exact lexical references', () => {
  for (const [name, body] of sources)
    for (const target of targets)
      for (const split of [false, true])
        for (const minify of [false, true]) {
          test(`${name}, ${target}, split=${split}, minify=${minify}`, async () => {
            const source =
              body +
              'console.log(JSON.stringify([value,typeof module,typeof exports,this===undefined]));';
            const fixture = await createFixture({
              'package.json': '{"type":"module"}',
              'entry.mjs': source,
              'second.mjs': source,
            });
            try {
              const native = spawnSync('node', [join(fixture.dir, 'entry.mjs')], {
                encoding: 'utf8',
              });
              expect(native.status, native.stderr).toBe(0);
              const args = ['--bundle', 'entry.mjs', '--format=esm', target];
              const output = split ? 'dist/entry.js' : 'output.mjs';
              if (split) args.push('second.mjs', '--splitting', '--outdir', 'dist');
              else args.push('-o', output);
              if (minify) args.push('--minify-syntax', '--minify-identifiers');
              const built = spawnSync(ZNTC_BIN, args, { cwd: fixture.dir, encoding: 'utf8' });
              expect(built.status, built.stderr).toBe(0);
              const runtime = spawnSync('node', [join(fixture.dir, output)], { encoding: 'utf8' });
              expect(runtime.status, runtime.stderr).toBe(0);
              expect(runtime.stdout).toBe(native.stdout);
            } finally {
              await fixture.cleanup();
            }
          });
        }
});

describe('actual CJS export writes retain their host wrapper', () => {
  const writes = [
    ['module assignment', 'module.exports={value:42};'],
    ['exports property', 'exports.value=42;'],
    ['root module var', 'var module;module.exports={value:42};'],
    ['root exports var', 'var exports;exports.value=42;'],
    ['define exports', 'Object.defineProperty(exports,"value",{value:42});'],
    ['define module', 'Object.defineProperty(module,"exports",{value:{value:42}});'],
  ] as const;
  for (const [name, write] of writes)
    for (const split of [false, true])
      for (const minify of [false, true]) {
        test(`${name}, split=${split}, minify=${minify}`, async () => {
          const source = write + 'console.log(module.exports.value,typeof module,typeof exports);';
          const fixture = await createFixture({
            'package.json': '{"type":"commonjs"}',
            'entry.cjs': source,
            'second.cjs': source,
          });
          try {
            const native = spawnSync('node', [join(fixture.dir, 'entry.cjs')], {
              encoding: 'utf8',
            });
            expect(native.status, native.stderr).toBe(0);
            const args = ['--bundle', 'entry.cjs', '--format=cjs', '--platform=react-native'];
            const output = split ? 'dist/entry.js' : 'output.cjs';
            if (split) args.push('second.cjs', '--splitting', '--outdir', 'dist');
            else args.push('-o', output);
            if (minify) args.push('--minify-syntax', '--minify-identifiers');
            const built = spawnSync(ZNTC_BIN, args, { cwd: fixture.dir, encoding: 'utf8' });
            expect(built.status, built.stderr).toBe(0);
            const runtime = spawnSync('node', [join(fixture.dir, output)], { encoding: 'utf8' });
            expect(runtime.status, runtime.stderr).toBe(0);
            expect(runtime.stdout).toBe(native.stdout);
          } finally {
            await fixture.cleanup();
          }
        });
      }
});

describe('CJS host reads survive async helper imports in UMD modules', () => {
  for (const kind of ['cjs', 'js-commonjs', 'js-unknown'])
    for (const target of targets)
      for (const minify of [false, true]) {
        test(`${kind}, ${target}, minify=${minify}`, async () => {
          const ext = kind === 'cjs' ? 'cjs' : 'js';
          const source =
            '(function(exports){exports.load=async function(){const loaded=await Promise.resolve(42);return [loaded,typeof module,typeof exports];};})(exports);';
          const files: Record<string, string> = {
            'entry.mjs': `import value from "./dep.${ext}";value.load().then(result=>console.log(JSON.stringify(result)));`,
            [`dep.${ext}`]: source,
            'leaf.mjs': 'export const value=42;',
          };
          if (kind !== 'js-unknown') files['package.json'] = '{"type":"commonjs"}';
          const fixture = await createFixture(files);
          try {
            const native = spawnSync('node', [join(fixture.dir, 'entry.mjs')], {
              encoding: 'utf8',
            });
            expect(native.status, native.stderr).toBe(0);
            const args = ['--bundle', 'entry.mjs', '--format=esm', target, '-o', 'output.mjs'];
            if (minify) args.push('--minify-syntax', '--minify-identifiers');
            const built = spawnSync(ZNTC_BIN, args, { cwd: fixture.dir, encoding: 'utf8' });
            expect(built.status, built.stderr).toBe(0);
            const runtime = spawnSync('node', [join(fixture.dir, 'output.mjs')], {
              encoding: 'utf8',
            });
            expect(runtime.status, runtime.stderr).toBe(0);
            expect(runtime.stdout).toBe(native.stdout);
          } finally {
            await fixture.cleanup();
          }
        });
      }
});

describe('escaped CJS host reads use the same source environment', () => {
  for (const minify of [false, true])
    test(`escaped exports, minify=${minify}`, async () => {
      const fixture = await createFixture({
        'package.json': '{"type":"commonjs"}',
        'dep.js': '(function(exports){exports.value=42;})(exp\\u006frts);',
        'entry.mjs': 'import value from "./dep.js";console.log(JSON.stringify(value));',
      });
      try {
        const native = spawnSync('node', [join(fixture.dir, 'entry.mjs')], { encoding: 'utf8' });
        expect(native.status, native.stderr).toBe(0);
        const args = [
          '--bundle',
          'entry.mjs',
          '--platform=react-native',
          '--format=esm',
          '-o',
          'out.mjs',
        ];
        if (minify) args.push('--minify-syntax', '--minify-identifiers');
        const built = spawnSync(ZNTC_BIN, args, { cwd: fixture.dir, encoding: 'utf8' });
        expect(built.status, built.stderr).toBe(0);
        const run = spawnSync('node', [join(fixture.dir, 'out.mjs')], { encoding: 'utf8' });
        expect(run.status, run.stderr).toBe(0);
        expect(run.stdout).toBe(native.stdout);
      } finally {
        await fixture.cleanup();
      }
    });
});
