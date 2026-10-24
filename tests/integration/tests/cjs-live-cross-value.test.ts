import { describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

const cases = [
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
