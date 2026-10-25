import { describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createFixture } from './helpers';
import { build, close, init } from '../../../packages/core/index';

const cases = [
  { name: 'success', entry: 'events.push(value());', expected: [42] },
  { name: 'entry throw', entry: 'throw new Error("entry");', expected: ['report:entry'] },
  {
    name: 'dependency throw',
    dep: 'throw new Error("dependency");export function value(){return 42;}',
    entry: 'events.push(value());',
    expected: ['report:dependency'],
  },
  {
    name: 'function throw',
    dep: 'export function value(){throw new Error("function");}',
    entry: 'value();',
    expected: ['report:function'],
  },
  {
    name: 'report receiver',
    entry: 'throw new Error("receiver");',
    receiver: true,
    expected: ['receiver:true', 'report:receiver'],
  },
  {
    name: 'report getter observations',
    entry: 'throw new Error("getter");',
    getter: true,
    expected: ['lookup', 'lookup', 'report:getter'],
  },
  {
    name: 'missing reporter preserves throw',
    entry: 'throw new Error("unhandled");',
    absent: true,
    expected: ['throw:unhandled'],
  },
  {
    name: 'reporter throw propagates',
    entry: 'throw new Error("original");',
    reporterThrows: true,
    expected: ['report:original', 'throw:reporter'],
  },
  {
    name: 'late reporter keeps evaluation boundary',
    dep: 'globalThis.ErrorUtils={reportFatalError(e){events.push("unexpected-report:"+e.message);}};events.push("install");export function value(){return 42;}',
    entry: 'value();throw new Error("late");',
    absent: true,
    expected: ['install', 'throw:late'],
  },
  {
    name: 'same spelling local decoys',
    entry:
      'const __zntc_guarded="guard",__zntc_in_guard="state",__zntc_guard_global="global",$zg="min",$zi="min-state",$zgG="min-global";events.push([value(),__zntc_guarded,__zntc_in_guard,__zntc_guard_global,$zg,$zi,$zgG]);',
    expected: [[42, 'guard', 'state', 'global', 'min', 'min-state', 'min-global']],
  },
] as const;

describe('split entry error guards use their exact provider', () => {
  for (const fixtureCase of cases) {
    for (const sourceFormat of ['esm', 'cjs'] as const) {
      for (const format of ['esm', 'cjs'] as const) {
        for (const minify of [false, true]) {
          test(`${fixtureCase.name}, input=${sourceFormat}, format=${format}, minify=${minify}`, async () => {
            const suffix = sourceFormat === 'cjs' ? 'cjs' : 'mjs';
            const entryName = `entry.${suffix}`;
            const secondName = `second.${suffix}`;
            const dependency =
              'dep' in fixtureCase ? fixtureCase.dep : 'export function value(){return 42;}';
            const readDependency =
              sourceFormat === 'cjs'
                ? `const{value}=require('./dep.${suffix}');`
                : `import {value} from './dep.${suffix}';`;
            const fixture = await createFixture({
              'package.json': '{"type":"module"}',
              [entryName]: `${readDependency}${fixtureCase.entry}`,
              [secondName]: `${readDependency}globalThis.secondValue=value;`,
              [`dep.${suffix}`]:
                sourceFormat === 'cjs'
                  ? dependency.replaceAll(
                      'export function value()',
                      'exports.value=function value()',
                    )
                  : dependency,
            });
            try {
              const dist = join(fixture.dir, 'dist');
              await init();
              const result = await build({
                entryPoints: [join(fixture.dir, entryName), join(fixture.dir, secondName)],
                rootDir: fixture.dir,
                outdir: dist,
                write: true,
                platform: 'react-native',
                format,
                splitting: true,
                minifySyntax: minify,
                minifyIdentifiers: minify,
                outExtension: format === 'cjs' ? '.cjs' : undefined,
              });
              expect(result.errors ?? []).toHaveLength(0);
              const entry = pathToFileURL(
                join(dist, format === 'cjs' ? 'entry.cjs' : 'entry.js'),
              ).href;
              const setup =
                'absent' in fixtureCase
                  ? ''
                  : `const reporter={marker:42,reportFatalError(e){${'receiver' in fixtureCase ? 'events.push("receiver:"+(this.marker===42));' : ''}events.push("report:"+e.message);${'reporterThrows' in fixtureCase ? 'throw new Error("reporter");' : ''}}};${'getter' in fixtureCase ? 'Object.defineProperty(globalThis,"ErrorUtils",{get(){events.push("lookup");return reporter;}});' : 'globalThis.ErrorUtils=reporter;'}`;
              const run = spawnSync(
                'node',
                [
                  '--input-type=module',
                  '-e',
                  `globalThis.events=[];${setup}try{await import(${JSON.stringify(entry)});}catch(e){events.push("throw:"+e.message);}console.log(JSON.stringify(events));`,
                ],
                { encoding: 'utf8' },
              );
              expect(run.status, run.stderr).toBe(0);
              expect(run.stdout.trim()).toBe(JSON.stringify(fixtureCase.expected));
            } finally {
              close();
              await fixture.cleanup();
            }
          });
        }
      }
    }
  }
});
