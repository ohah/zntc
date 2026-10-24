import { describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

const imports = `import {__export as publish} from '\\x00zntc:runtime/export';
import {__toCommonJS as convert} from '\\x00zntc:runtime/to-commonjs';\n`;
const inputs = [
  [
    'live export',
    'let value=1;const target={};publish(target,{value:()=>value});value=3;return [target.value,Object.keys(target)];',
    [3, ['value']],
  ],
  [
    'multiple exports',
    'const target={};publish(target,{first:()=>3,second:()=>4});return [target.first,target.second];',
    [3, 4],
  ],
  [
    'existing namespace property',
    'const target={existing:1};publish(target,{value:()=>2});return [target.existing,target.value];',
    [1, 2],
  ],
  [
    'live CommonJS view',
    'let value=1;const result=convert({get value(){return value;}});value=5;return [result.value,result.__esModule];',
    [5, true],
  ],
  ['explicit module.exports', 'return convert({"module.exports":{value:9},other:2}).value;', 9],
  ['undefined module.exports', 'return convert({"module.exports":undefined})===undefined;', true],
  [
    'inherited module.exports',
    'const ns=Object.create({"module.exports":{value:0}});ns.value=6;const result=convert(ns);return [result.value,Object.hasOwn(result,"module.exports")];',
    [6, false],
  ],
  [
    'non enumerable property',
    'const ns={};Object.defineProperty(ns,"hidden",{value:7,enumerable:false});const result=convert(ns);return [result.hidden,Object.keys(result),Object.getOwnPropertyDescriptor(result,"hidden").enumerable];',
    [7, [], false],
  ],
  [
    'deferred throwing getter',
    'const result=convert({get fail(){throw new Error("deferred");}});try{return result.fail;}catch(error){return error.message;}',
    'deferred',
  ],
  [
    'helper name decoys',
    'const __defProp="a",__copyProps="b",__hasOwn="c",$dp="d",$cp="e",$hO="f";const ns={};publish(ns,{value:()=>10});return [convert(ns).value,__defProp,__copyProps,__hasOwn,$dp,$cp,$hO];',
    [10, 'a', 'b', 'c', 'd', 'e', 'f'],
  ],
] as const;

const targets = ['--target=es5', '--target=es2017', '--platform=react-native'];

describe('runtime helper variant dependencies (#4819)', () => {
  for (const [name, body, expected] of inputs) {
    for (const target of targets) {
      for (const split of [false, true]) {
        for (const minify of [false, true]) {
          test(`${name}, ${target}, split=${split}, minify=${minify}`, async () => {
            const fixture = await createFixture({
              'package.json': '{"type":"module"}',
              'entry.mjs': imports + `console.log(JSON.stringify((function(){${body}})()));`,
              // A second entry keeps both virtual modules and their provider shared.
              'second.mjs':
                imports +
                'const value={};publish(value,{value:()=>11});console.log(convert(value).value);',
            });
            try {
              const output = join(fixture.dir, split ? 'dist/entry.js' : 'output.mjs');
              const args = ['--bundle', 'entry.mjs', '--format=esm', target];
              if (split) args.push('second.mjs', '--splitting', '--outdir', 'dist');
              else args.push('-o', output);
              if (minify) args.push('--minify-syntax', '--minify-identifiers');
              const result = spawnSync(ZNTC_BIN, args, {
                cwd: fixture.dir,
                encoding: 'utf8',
                env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
              });
              expect(result.status, result.stderr).toBe(0);
              const reports = result.stderr
                .split(/\r?\n/)
                .filter(
                  (line) =>
                    line.startsWith('zntc: symbol-identity-prepass ') &&
                    /runtime\/(export|to-commonjs|to-esm):/.test(line),
                );
              // Plain helper sources may skip the transform prepass entirely.
              // The module-mode parser census checks every source variant separately.
              if (minify) expect(reports.length).toBeGreaterThanOrEqual(2);
              for (const report of reports) expect(report).toMatch(/clean=1(?:\s|$)/);
              const runtime = spawnSync('node', [output], { encoding: 'utf8' });
              expect(runtime.status, runtime.stderr).toBe(0);
              expect(runtime.stdout.trim()).toBe(JSON.stringify(expected));
            } finally {
              await fixture.cleanup();
            }
          });
        }
      }
    }
  }
});

describe('runtime helper dependency intrinsic cache boundary', () => {
  for (const property of [
    'defineProperty',
    'getOwnPropertyDescriptor',
    'getOwnPropertyNames',
    'hasOwnProperty',
  ]) {
    for (const split of [false, true]) {
      for (const sharedPatch of split ? [false, true] : [false]) {
        for (const minify of [false, true]) {
          test(`${property}, split=${split}, sharedPatch=${sharedPatch}, minify=${minify}`, async () => {
            const owner = property === 'hasOwnProperty' ? 'Object.prototype' : 'Object';
            const patch = `export const stats={reads:0,calls:0};
export const set=Object.defineProperty;
const original=${owner}.${property};
set(${owner},'${property}',{configurable:true,get(){stats.reads++;return function(){stats.calls++;return original.apply(this,arguments);}}});\n`;
            const entry =
              `import {stats,set} from './patch.mjs';\n` +
              imports +
              `
set(${owner},'${property}',{configurable:true,writable:true,value:function(){throw new Error('late intrinsic used');}});
const value={};publish(value,{value:()=>42});const result=convert(value);
console.log(JSON.stringify([result.value,stats.reads,stats.calls>0]));`;
            const fixture = await createFixture({
              'package.json': '{"type":"module"}',
              'patch.mjs': patch,
              'entry.mjs': entry,
              'second.mjs':
                (sharedPatch ? 'import {stats} from "./patch.mjs";console.log(stats.reads);' : '') +
                imports +
                'const value={};publish(value,{value:()=>2});console.log(convert(value).value);',
            });
            try {
              const output = join(fixture.dir, split ? 'dist/entry.js' : 'output.mjs');
              const args = ['--bundle', 'entry.mjs', '--format=esm', '--target=es5'];
              if (split) args.push('second.mjs', '--splitting', '--outdir', 'dist');
              else args.push('-o', output);
              if (minify) args.push('--minify-syntax', '--minify-identifiers');
              const built = spawnSync(ZNTC_BIN, args, { cwd: fixture.dir, encoding: 'utf8' });
              expect(built.status, built.stderr).toBe(0);
              const runtime = spawnSync('node', [output], { encoding: 'utf8' });
              expect(runtime.status, runtime.stderr).toBe(0);
              expect(runtime.stdout.trim()).toBe(
                split && !sharedPatch ? '[42,0,false]' : '[42,1,true]',
              );
            } finally {
              await fixture.cleanup();
            }
          });
        }
      }
    }
  }
});

describe('commonjs virtual module exposes only its real factory', () => {
  for (const target of targets)
    for (const split of [false, true])
      for (const minify of [false, true]) {
        test(`factory cached identity, ${target}, split=${split}, minify=${minify}`, async () => {
          const source =
            'import {__commonJS as makeCommon} from "\\x00zntc:runtime/commonjs";let calls=0;const load=makeCommon({"value.cjs":function(exports,module){calls++;module.exports={value:42};}});const first=load();console.log(JSON.stringify([first.value,first===load(),calls]));';
          const fixture = await createFixture({
            'package.json': '{"type":"module"}',
            'entry.mjs': source,
            'second.mjs': source,
          });
          try {
            const output = split ? 'dist/entry.js' : 'output.mjs';
            const args = ['--bundle', 'entry.mjs', '--format=esm', target];
            if (split) args.push('second.mjs', '--splitting', '--outdir', 'dist');
            else args.push('-o', output);
            if (minify) args.push('--minify-syntax', '--minify-identifiers');
            const build = spawnSync(ZNTC_BIN, args, { cwd: fixture.dir, encoding: 'utf8' });
            expect(build.status, build.stderr).toBe(0);
            const run = spawnSync('node', [join(fixture.dir, output)], { encoding: 'utf8' });
            expect(run.status, run.stderr).toBe(0);
            expect(run.stdout.trim()).toBe('[42,true,1]');
          } finally {
            await fixture.cleanup();
          }
        });
      }
  for (const split of [false, true])
    for (const minify of [false, true]) {
      test(`private require name is not a public export, split=${split}, minify=${minify}`, async () => {
        const source =
          'import {__require as phantom} from "\\x00zntc:runtime/commonjs";console.log(phantom());';
        const fixture = await createFixture({
          'package.json': '{"type":"module"}',
          'entry.mjs': source,
          'second.mjs': source,
        });
        try {
          const args = ['--bundle', 'entry.mjs', '--format=esm', '--target=es5'];
          if (split) args.push('second.mjs', '--splitting', '--outdir', 'dist');
          else args.push('-o', 'output.mjs');
          if (minify) args.push('--minify-syntax', '--minify-identifiers');
          const built = spawnSync(ZNTC_BIN, args, { cwd: fixture.dir, encoding: 'utf8' });
          expect(built.status).not.toBe(0);
          expect(built.stderr).toContain('__require');
        } finally {
          await fixture.cleanup();
        }
      });
    }
});
