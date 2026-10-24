import { describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import ts from 'typescript';
import { createFixture, ZNTC_BIN } from './helpers';

const cases = [
  {
    name: 'namespace tag receiver',
    deps: {
      'dep.mjs':
        'export const marker="namespace";export function tag(){"use strict";return this.marker;}',
    },
    entry: 'import * as ns from "./dep.mjs";console.log(ns.tag`text`);',
  },
  {
    name: 'mutable live value',
    deps: { 'dep.mjs': 'export let value=1;export function change(){value=2;}' },
    entry: 'import {value,change} from "./dep.mjs";console.log(value);change();console.log(value);',
  },
  {
    name: 'named function unbound this',
    deps: { 'dep.mjs': 'export function read(){"use strict";return this===undefined;}' },
    entry: 'import {read} from "./dep.mjs";console.log(read());',
  },
  {
    name: 'namespace method receiver',
    deps: {
      'dep.mjs':
        'export const marker="namespace";export function read(){"use strict";return this.marker;}',
    },
    entry: 'import * as ns from "./dep.mjs";console.log(ns.read());',
  },
  {
    name: 'tag unbound this',
    deps: { 'dep.mjs': 'export function tag(){"use strict";return this===undefined;}' },
    entry: 'import {tag} from "./dep.mjs";console.log(tag`text`);',
  },
  {
    name: 'default callable',
    deps: { 'dep.mjs': 'export default function(){return 42;}' },
    entry: 'import read from "./dep.mjs";console.log(read());',
  },
  {
    name: 'class constructor',
    deps: { 'dep.mjs': 'export class Box{constructor(){this.value=42;}}' },
    entry: 'import {Box} from "./dep.mjs";console.log(new Box().value);',
  },
  {
    name: 'namespace identity',
    deps: { 'dep.mjs': 'export const marker="namespace";' },
    entry:
      'import * as left from "./dep.mjs";import * as right from "./dep.mjs";console.log(left===right,left.marker);',
  },

  {
    name: 'namespace object identity decoys',
    deps: {
      'dep.mjs':
        'export const exports_dep="source";export const __export="helper decoy";export const value=42;',
    },
    entry: 'import * as ns from "./dep.mjs";console.log(ns.value,ns.exports_dep,ns.__export);',
  },
  {
    name: 'direct',
    deps: { 'dep.mjs': 'export function answer(){return 42;}' },
    entry: 'import {answer} from "./dep.mjs";console.log(answer());',
  },
  {
    name: 'alias',
    deps: { 'dep.mjs': 'export function answer(){return 42;}' },
    entry: 'import {answer as read} from "./dep.mjs";console.log(read());',
  },
  {
    name: 'same numbered foreign symbols',
    deps: {
      'a.mjs': 'export function left(){return "left";}',
      'b.mjs': 'export function right(){return "right";}',
    },
    entry:
      'import {left} from "./a.mjs";import {right} from "./b.mjs";console.log(left(),right());',
  },
  {
    name: 'same basename owners',
    deps: {
      'left/dep.mjs': 'export function answer(){return 1;}',
      'right/dep.mjs': 'export function answer(){return 2;}',
    },
    entry:
      'import {answer as left} from "./left/dep.mjs";import {answer as right} from "./right/dep.mjs";console.log(left(),right());',
  },
  {
    name: 're export',
    deps: {
      'leaf.mjs': 'export function answer(){return 42;}',
      'barrel.mjs': 'export {answer} from "./leaf.mjs";',
    },
    entry: 'import {answer} from "./barrel.mjs";console.log(answer());',
  },
  {
    name: 'namespace',
    deps: { 'dep.mjs': 'export function answer(){return 42;}' },
    entry: 'import * as ns from "./dep.mjs";console.log(ns.answer());',
  },
  {
    name: 'namespace escape',
    deps: { 'dep.mjs': 'export const value=42;' },
    entry:
      'import * as ns from "./dep.mjs";function read(value){return value.value;}console.log(read(ns));',
  },
  {
    name: 'nested foreign init capture',
    deps: { 'dep.mjs': 'export function answer(){return 42;}' },
    entry:
      'import {answer} from "./dep.mjs";console.log((function(){const __defProp="a",__copyProps="b",__hasOwn="c",$dp="d",$cp="e",$hO="f";return [answer(),__defProp,__copyProps,__hasOwn,$dp,$cp,$hO].join(",");})());',
  },
  {
    name: 'source init name decoys',
    deps: { 'dep.mjs': 'export function answer(){return 42;}' },
    entry:
      'import {answer} from "./dep.mjs";function read(){const init_dep="decoy",init_dep$1="other";return [answer(),init_dep,init_dep$1];}console.log(JSON.stringify(read()));',
  },
  {
    name: 'cycle owner',
    deps: {
      'a.mjs': 'import {other} from "./b.mjs";export function answer(){return other()+1;}',
      'b.mjs':
        'import {answer} from "./a.mjs";export function other(){return 41;}export function read(){return answer();}',
    },
    entry: 'import {answer} from "./a.mjs";console.log(answer());',
  },
] as const;

describe('CJS live cross-chunk values (#4819)', () => {
  for (const input of cases) {
    for (const split of [false, true]) {
      for (const minify of [false, true]) {
        test(`${input.name}, split=${split}, minify=${minify}`, async () => {
          const fixture = await createFixture({
            'package.json': '{"type":"commonjs"}',
            ...input.deps,
            'entry.mjs': input.entry,
            'second.mjs': input.entry,
          });
          try {
            const native = spawnSync('node', [join(fixture.dir, 'entry.mjs')], {
              encoding: 'utf8',
            });
            expect(native.status, native.stderr).toBe(0);
            const output = join(fixture.dir, split ? 'dist/entry.js' : 'output.cjs');
            const args = ['--bundle', 'entry.mjs', '--platform=react-native', '--format=cjs'];
            if (split) args.push('second.mjs', '--splitting', '--outdir', 'dist');
            else args.push('-o', output);
            if (minify) args.push('--minify-syntax', '--minify-identifiers');
            const built = spawnSync(ZNTC_BIN, args, { cwd: fixture.dir, encoding: 'utf8' });
            expect(built.status, built.stderr).toBe(0);
            const runtime = spawnSync('node', [output], { encoding: 'utf8' });
            expect(runtime.status, runtime.stderr).toBe(0);
            expect(runtime.stdout).toBe(native.stdout);
          } finally {
            await fixture.cleanup();
          }
        });
      }
    }
  }
});

describe('ESM wrapper edge negative controls', () => {
  for (const minify of [false, true]) {
    for (const wrapped of [false, true]) {
      test(`unused owner emits no wrapper edge, wrapped=${wrapped}, minify=${minify}`, async () => {
        const source =
          'import {unused} from "./unused.mjs";import {answer} from "./dep.mjs";console.log(answer());';
        const fixture = await createFixture({
          'package.json': '{"type":"commonjs","sideEffects":false}',
          'entry.mjs': source,
          'second.mjs': source,
          'dep.mjs': 'export function answer(){return 42;}',
          'unused.mjs': 'export function unused(){return "UNUSED_OWNER_SENTINEL";}',
        });
        try {
          const args = [
            '--bundle',
            'entry.mjs',
            'second.mjs',
            '--format=cjs',
            '--splitting',
            '--outdir',
            'dist',
            wrapped ? '--platform=react-native' : '--platform=node',
          ];
          if (minify) args.push('--minify-syntax', '--minify-identifiers');
          const built = spawnSync(ZNTC_BIN, args, { cwd: fixture.dir, encoding: 'utf8' });
          expect(built.status, built.stderr).toBe(0);
          const runtime = spawnSync('node', [join(fixture.dir, 'dist/entry.js')], {
            encoding: 'utf8',
          });
          expect(runtime.status, runtime.stderr).toBe(0);
          expect(runtime.stdout.trim()).toBe('42');
          const { readdirSync, readFileSync } = await import('node:fs');
          const output = readdirSync(join(fixture.dir, 'dist'))
            .filter((file) => file.endsWith('.js'))
            .map((file) => readFileSync(join(fixture.dir, 'dist', file), 'utf8'))
            .join('\n');
          expect(output).not.toContain('UNUSED_OWNER_SENTINEL');
          expect(output).not.toContain('init_unused');
          if (!wrapped) expect(output).not.toContain('init_dep');
        } finally {
          await fixture.cleanup();
        }
      });
    }
  }
});

describe('CJS generated imports honor ES5 binding syntax', () => {
  for (const cjs of [false, true]) {
    for (const rn of [false, true]) {
      for (const preserve of [false, true]) {
        for (const minify of [false, true]) {
          test(`cjs=${cjs}, rn=${rn}, preserve=${preserve}, minify=${minify}`, async () => {
            const dependency = cjs ? 'dep.cjs' : 'dep.mjs';
            const source = `import {answer} from './${dependency}';console.log(answer());`;
            const fixture = await createFixture({
              'package.json': '{"type":"commonjs"}',
              'entry.mjs': source,
              'second.mjs': source,
              [dependency]: cjs
                ? 'module.exports={answer:function(){return 42;}};'
                : 'export function answer(){return 42;}',
            });
            try {
              const args = [
                '--bundle',
                'entry.mjs',
                'second.mjs',
                '--format=cjs',
                '--splitting',
                '--outdir',
                'dist',
                '--target=es5',
                rn ? '--platform=react-native' : '--platform=node',
              ];
              if (preserve)
                args.push('--preserve-modules', `--preserve-modules-root=${fixture.dir}`);
              if (minify) args.push('--minify-syntax', '--minify-identifiers');
              const built = spawnSync(ZNTC_BIN, args, { cwd: fixture.dir, encoding: 'utf8' });
              expect(built.status, built.stderr).toBe(0);
              const runtime = spawnSync('node', [join(fixture.dir, 'dist/entry.js')], {
                encoding: 'utf8',
              });
              expect(runtime.status, runtime.stderr).toBe(0);
              expect(runtime.stdout.trim()).toBe('42');
              const { readdirSync, readFileSync } = await import('node:fs');
              for (const file of readdirSync(join(fixture.dir, 'dist')).filter((file) =>
                file.endsWith('.js'),
              )) {
                const text = readFileSync(join(fixture.dir, 'dist', file), 'utf8');
                const parsed = ts.createSourceFile(
                  file,
                  text,
                  ts.ScriptTarget.ES5,
                  true,
                  ts.ScriptKind.JS,
                );
                const forbidden: string[] = [];
                const visit = (node: ts.Node) => {
                  if (
                    ts.isVariableDeclarationList(node) &&
                    node.flags & (ts.NodeFlags.Const | ts.NodeFlags.Let)
                  )
                    forbidden.push(node.getText(parsed));
                  if (
                    ts.isVariableDeclaration(node) &&
                    (ts.isObjectBindingPattern(node.name) || ts.isArrayBindingPattern(node.name))
                  )
                    forbidden.push(node.getText(parsed));
                  ts.forEachChild(node, visit);
                };
                visit(parsed);
                expect(forbidden, `${file}: unsupported lexical/destructuring binding`).toEqual([]);
              }
            } finally {
              await fixture.cleanup();
            }
          });
        }
      }
    }
  }
});

describe('CJS live namespace instantiation across real chunk cycles', () => {
  for (const earlyCall of [false, true]) {
    for (const es5 of [false, true]) {
      for (const minify of [false, true]) {
        test(`manual cycle, earlyCall=${earlyCall}, es5=${es5}, minify=${minify}`, async () => {
          const fixture = await createFixture({
            'package.json': '{"type":"commonjs","sideEffects":true}',
            'trace.mjs': 'export const events=[];',
            'left.mjs':
              'import {readRight} from "./right.mjs";import {events} from "./trace.mjs";events.push("left body");export function left(){return "left";}export function read(){return readRight()+left();}',
            'right.mjs':
              'import {left} from "./left.mjs";import {events} from "./trace.mjs";events.push("right body");' +
              (earlyCall ? 'events.push(left());' : '') +
              'export function readRight(){return left()+"right";}',
            'entry.mjs':
              'import {read} from "./left.mjs";import {events} from "./trace.mjs";console.log(JSON.stringify([read(),events]));',
            'second.mjs': 'import {readRight} from "./right.mjs";console.log(readRight());',
            'zntc.config.json': JSON.stringify({
              manualChunks: [
                { name: 'left', patterns: ['left.mjs'] },
                { name: 'right', patterns: ['right.mjs'] },
              ],
            }),
          });
          try {
            const native = spawnSync('node', [join(fixture.dir, 'entry.mjs')], {
              encoding: 'utf8',
            });
            expect(native.status, native.stderr).toBe(0);
            const args = [
              '--bundle',
              'entry.mjs',
              'second.mjs',
              '--platform=react-native',
              '--format=cjs',
              '--splitting',
              '--outdir',
              'dist',
            ];
            if (es5) args.push('--target=es5');
            if (minify) args.push('--minify-syntax', '--minify-identifiers');
            const built = spawnSync(ZNTC_BIN, args, { cwd: fixture.dir, encoding: 'utf8' });
            expect(built.status, built.stderr).toBe(0);
            const { readdirSync } = await import('node:fs');
            const files = readdirSync(join(fixture.dir, 'dist'));
            expect(files.some((file) => file.startsWith('left-'))).toBe(true);
            expect(files.some((file) => file.startsWith('right-'))).toBe(true);
            const runtime = spawnSync('node', [join(fixture.dir, 'dist/entry.js')], {
              encoding: 'utf8',
            });
            expect(runtime.status, runtime.stderr).toBe(0);
            expect(runtime.stdout).toBe(native.stdout);
          } finally {
            await fixture.cleanup();
          }
        });
      }
    }
  }
});

describe('binding-less wrapper record callers retain exact handles', () => {
  for (const requireRecord of [false, true]) {
    for (const format of ['esm', 'cjs']) {
      for (const split of [false, true]) {
        for (const minify of [false, true]) {
          test(`require=${requireRecord}, format=${format}, split=${split}, minify=${minify}`, async () => {
            const entry = requireRecord ? 'entry.cjs' : 'entry.mjs';
            const second = requireRecord ? 'second.cjs' : 'second.mjs';
            const locals = Array.from({ length: 26 }, (_, i) => `var local${i}=seed+${i};`).join(
              '',
            );
            const values = Array.from({ length: 26 }, (_, i) => `local${i}`).join(',');
            const source = requireRecord
              ? `function read(seed){${locals}var value=require('./dep.mjs');return [value.answer(),${values}].join(',');}console.log(read(1));`
              : 'import "./dep.mjs";const init_dep="source decoy",exports_dep="namespace decoy",n=1,s=2,c=3;console.log(init_dep,exports_dep,n,s,c);';
            const fixture = await createFixture({
              'package.json': '{"type":"commonjs","sideEffects":true}',
              [entry]: source,
              [second]: source,
              'dep.mjs': requireRecord
                ? 'export function answer(){return 42;}'
                : 'console.log("dependency");',
            });
            try {
              const native = spawnSync('node', [join(fixture.dir, entry)], { encoding: 'utf8' });
              expect(native.status, native.stderr).toBe(0);
              const output = split
                ? `dist/${entry.replace(/\.(mjs|cjs)$/, '.js')}`
                : format === 'cjs'
                  ? 'output.cjs'
                  : 'output.mjs';
              const args = ['--bundle', entry, '--platform=react-native', `--format=${format}`];
              if (split) args.push(second, '--splitting', '--outdir', 'dist');
              else args.push('-o', output);
              if (minify) args.push('--minify-syntax', '--minify-identifiers');
              const built = spawnSync(ZNTC_BIN, args, { cwd: fixture.dir, encoding: 'utf8' });
              expect(built.status, built.stderr).toBe(0);
              if (format === 'esm' && split) {
                const { writeFileSync } = await import('node:fs');
                writeFileSync(join(fixture.dir, 'dist/package.json'), '{"type":"module"}');
              }
              const runtime = spawnSync('node', [join(fixture.dir, output)], { encoding: 'utf8' });
              expect(runtime.status, runtime.stderr).toBe(0);
              expect(runtime.stdout).toBe(native.stdout);
            } finally {
              await fixture.cleanup();
            }
          });
        }
      }
    }
  }
});

describe('wrapped re-export namespace getter uses actual owner', () => {
  for (const format of ['esm', 'cjs']) {
    for (const minify of [false, true]) {
      test(`barrel raw require, format=${format}, minify=${minify}`, async () => {
        const fixture = await createFixture({
          'package.json': '{"type":"commonjs","sideEffects":true}',
          'leaf.mjs': 'export let answer=42;export function change(){answer=43;}',
          'barrel.mjs': 'export {answer,change} from "./leaf.mjs";',
          'entry.cjs':
            'var value=require("./barrel.mjs");console.log(value.answer);value.change();console.log(value.answer);',
          'second.mjs': 'import {answer} from "./leaf.mjs";console.log(answer);',
          'zntc.config.json': JSON.stringify({
            manualChunks: [
              { name: 'leaf', patterns: ['leaf.mjs'] },
              { name: 'barrel', patterns: ['barrel.mjs'] },
            ],
          }),
        });
        try {
          const native = spawnSync('node', [join(fixture.dir, 'entry.cjs')], { encoding: 'utf8' });
          expect(native.status, native.stderr).toBe(0);
          const args = [
            '--bundle',
            'entry.cjs',
            'second.mjs',
            '--platform=react-native',
            `--format=${format}`,
            '--splitting',
            '--outdir',
            'dist',
          ];
          if (minify) args.push('--minify-syntax', '--minify-identifiers');
          const built = spawnSync(ZNTC_BIN, args, { cwd: fixture.dir, encoding: 'utf8' });
          expect(built.status, built.stderr).toBe(0);
          if (format === 'esm') {
            const { writeFileSync } = await import('node:fs');
            writeFileSync(join(fixture.dir, 'dist/package.json'), '{"type":"module"}');
          }
          const runtime = spawnSync('node', [join(fixture.dir, 'dist/entry.js')], {
            encoding: 'utf8',
          });
          expect(runtime.status, runtime.stderr).toBe(0);
          expect(runtime.stdout).toBe(native.stdout);
        } finally {
          await fixture.cleanup();
        }
      });
    }
  }
});

describe('raw CJS require wrapper prefix honors ES5 syntax', () => {
  for (const platform of ['node', 'react-native']) {
    for (const minify of [false, true]) {
      test(`raw CJS require, platform=${platform}, minify=${minify}`, async () => {
        const fixture = await createFixture({
          'package.json': '{"type":"commonjs","sideEffects":true}',
          'dep.cjs': 'module.exports={answer:function(){return 42;}};',
          'entry.cjs': 'console.log(require("./dep.cjs").answer());',
          'second.cjs': 'console.log(require("./dep.cjs").answer());',
        });
        try {
          const args = [
            '--bundle',
            'entry.cjs',
            'second.cjs',
            `--platform=${platform}`,
            '--format=cjs',
            '--target=es5',
            '--splitting',
            '--outdir',
            'dist',
          ];
          if (minify) args.push('--minify-syntax', '--minify-identifiers');
          const built = spawnSync(ZNTC_BIN, args, { cwd: fixture.dir, encoding: 'utf8' });
          expect(built.status, built.stderr).toBe(0);
          const { readdirSync, readFileSync } = await import('node:fs');
          for (const file of readdirSync(join(fixture.dir, 'dist')).filter((file) =>
            file.endsWith('.js'),
          )) {
            const parsed = ts.createSourceFile(
              file,
              readFileSync(join(fixture.dir, 'dist', file), 'utf8'),
              ts.ScriptTarget.ES5,
              true,
            );
            const forbidden: string[] = [];
            const visit = (node: ts.Node) => {
              if (
                ts.isVariableDeclarationList(node) &&
                node.flags & (ts.NodeFlags.Let | ts.NodeFlags.Const)
              )
                forbidden.push(node.getText(parsed));
              if (
                ts.isVariableDeclaration(node) &&
                (ts.isObjectBindingPattern(node.name) || ts.isArrayBindingPattern(node.name))
              )
                forbidden.push(node.getText(parsed));
              ts.forEachChild(node, visit);
            };
            visit(parsed);
            expect(forbidden, file).toEqual([]);
          }
          const runtime = spawnSync('node', [join(fixture.dir, 'dist/entry.js')], {
            encoding: 'utf8',
          });
          expect(runtime.status, runtime.stderr).toBe(0);
          expect(runtime.stdout).toBe('42\n');
        } finally {
          await fixture.cleanup();
        }
      });
    }
  }
});
