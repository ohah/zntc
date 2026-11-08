import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { build, buildSync, close, init, type BuildOptions } from '../../../packages/core/index.ts';
import { createFixture, ZNTC_BIN } from './helpers';

// #6959: the original native-module cases must also work in one output file.
// Preserve the same source and options as the PM suite. The mixed exported
// resource has an explicit Node 26.9 observation distinct from DisposeResources.
const surfaces =
  process.env.ZNTC_TEST_CLI_ONLY === '1' ? (['cli'] as const) : (['cli', 'sync', 'async'] as const);
type Surface = 'cli' | 'sync' | 'async';
type Input = {
  name: string;
  lib: string;
  entry: string;
  peer?: string;
  consumer?: string;
  specStdout?: string;
  node269ObservedStdout?: string;
};
const inputs: Input[] = [
  {
    name: 'public var initialized inside a source block',
    lib: 'await using resource=null;{var value=1}export{value};export function advance(){value++}',
    entry: "export{value,advance}from './lib.mjs';",
    consumer:
      "import*as ns from './ENTRY';const initial=ns.value;ns.advance();console.log(JSON.stringify([initial,ns.value]));",
  },
  {
    name: 'public export aliases and native write targets',
    lib: "await using resource=null;var value=1;var value;export{value,value as alias};export let named;export function advance(){const before=value++;const after=++value;value+=2;value*=2;value&&=12;({value}={value:13});[value]=[14];try{value=(()=>{throw Error('stop')})()}catch{}({named=class{static label=this.name}}={});return [before,after,value,named.name,named.label]}",
    entry: "export{value,alias,named,advance}from './lib.mjs';",
    consumer:
      "import*as ns from './ENTRY';const initial=[ns.value,ns.alias];const result=ns.advance();console.log(JSON.stringify([initial,result,ns.value,ns.alias,ns.named.name,ns.named.label]));",
  },
  {
    name: 'original static dependency',
    lib: "import{events}from './log.mjs';await using r={async[Symbol.asyncDispose](){events.push('dispose-start');await Promise.resolve();events.push('dispose-end')}};events.push('body');export const answer=42;",
    entry:
      "import{events}from './log.mjs';import{answer}from './lib.mjs';events.push('entry');console.log(JSON.stringify([answer,events]));",
  },
  {
    name: 'async LIFO',
    lib: "import{events}from './log.mjs';const r=n=>({async[Symbol.asyncDispose](){events.push(n+':start');await 0;events.push(n+':end')}});await using a=r('a');await using b=r('b');events.push('body');export const answer=42;",
    entry:
      "import{events}from './log.mjs';import{answer}from './lib.mjs';events.push('entry');console.log(JSON.stringify([answer,events]));",
  },
  {
    name: 'null async hint and microtasks',
    lib: "import{events}from './log.mjs';let n=0;function tick(){events.push('tick:'+n);if(++n<8)queueMicrotask(tick)}queueMicrotask(tick);await using r=null;events.push('body');export const answer=42;",
    entry:
      "import{events}from './log.mjs';import{answer}from './lib.mjs';events.push('entry');console.log(JSON.stringify([answer,events]));",
  },
  {
    name: 'body error and two throwing disposers',
    lib: "import{events}from './log.mjs';const r=n=>({async[Symbol.asyncDispose](){events.push(n);await 0;throw n}});await using a=r('a');await using b=r('b');throw 'body';",
    entry:
      "import{events}from './log.mjs';const shape=e=>e instanceof SuppressedError?[shape(e.error),shape(e.suppressed)]:e;try{await import('./lib.mjs')}catch(e){console.log(JSON.stringify([shape(e),events]))}",
  },
  {
    name: 'acquisition failure disposes prior resource',
    lib: "import{events}from './log.mjs';await using a={async[Symbol.asyncDispose](){events.push('dispose-start');await 0;events.push('dispose-end')}};await using b={get[Symbol.asyncDispose](){events.push('getter');throw 'acquire'}};",
    entry:
      "import{events}from './log.mjs';try{await import('./lib.mjs')}catch(e){events.push(e);console.log(JSON.stringify(events))}",
  },
  {
    name: 'mixed exported resource',
    // ECMA-262 DisposeResources has no exemption for exported sync resources.
    // Exact source also yields specStdout in Bun; Node 26.9 omits only 'sync'.
    specStdout: '["ok",["async-start","async-end","sync","entry"]]\n',
    node269ObservedStdout: '["ok",["async-start","async-end","entry"]]\n',
    lib: "import{events}from './log.mjs';using resource={label:'ok',[Symbol.dispose](){events.push('sync')}};await using other={async[Symbol.asyncDispose](){events.push('async-start');await 0;events.push('async-end')}};export{resource};",
    entry:
      "import{events}from './log.mjs';const{resource}=await import('./lib.mjs');events.push('entry');console.log(JSON.stringify([resource.label,events]));",
  },
  {
    name: 'own const and class TDZ',
    lib: "import{events}from './log.mjs';function read(){return [value,Named]}for(const get of [()=>value,()=>Named]){try{get()}catch(e){events.push(e.name)}}await using r={async[Symbol.asyncDispose](){await 0;events.push(read()[0])}};const value=42;class Named{}export{read};",
    entry:
      "import{events}from './log.mjs';import{read}from './lib.mjs';console.log(JSON.stringify([read()[0],events]));",
  },
  {
    name: 'cycle hoisted function and source TDZ',
    lib: "import{events}from './log.mjs';import{probe}from './peer.mjs';export function read(){return answer}events.push(probe());await using r={async[Symbol.asyncDispose](){await 0;events.push('dispose')}};export const answer=42;",
    peer: "import{read}from './lib.mjs';export function probe(){try{return read()}catch(e){return e.name}}",
    entry:
      "import{events}from './log.mjs';import{answer}from './lib.mjs';console.log(JSON.stringify([answer,events]));",
  },
  {
    name: 'external ESM live binding and default snapshot',
    lib: 'await using r={async[Symbol.asyncDispose](){await 0}};export let value=1;export default value;export function advance(){value++}',
    entry: "export{default,value,advance}from './lib.mjs';",
    consumer:
      "import initial,*as ns from './ENTRY';ns.advance();const first=ns.value;ns.advance();console.log(JSON.stringify([initial,first,ns.value]));",
  },
  {
    name: 'ordinary await before native disposal',
    lib: "import{events}from './log.mjs';await using r={async[Symbol.asyncDispose](){events.push('dispose-start');await 0;events.push('dispose-end')}};events.push('body');await 0;events.push('resumed');export const answer=42;",
    entry:
      "import{events}from './log.mjs';import{answer}from './lib.mjs';events.push('entry');console.log(JSON.stringify([answer,events]));",
  },
];
const modes = [false, true] as const;
const node = process.env.ZNTC_NODE_BIN ?? 'node';
const nodeVersion = spawnSync(node, ['--version'], { encoding: 'utf8' }).stdout.trim();
function execute(path: string, cwd: string) {
  return spawnSync(node, [path], { cwd, encoding: 'utf8', timeout: 15_000 });
}
async function compile(
  surface: Surface,
  dir: string,
  minify: boolean,
  preserve: boolean,
  format: 'esm' | 'cjs' = 'esm',
  target: BuildOptions['target'] = 'esnext',
) {
  const outdir = join(dir, 'dist');
  const outfile = join(outdir, format === 'cjs' ? 'entry.cjs' : 'entry.mjs');
  const options: BuildOptions = {
    entryPoints: [join(dir, 'entry.mjs')],
    rootDir: dir,
    format,
    target,
    tsconfigRaw: '{}',
    keepNames: true,
    platform: 'node',
    write: true,
    minify,
    ...(preserve
      ? { outdir, preserveModules: true, preserveModulesRoot: dir, outExtension: '.mjs' }
      : { outfile }),
  };
  if (surface === 'cli') {
    const result = spawnSync(
      process.env.ZNTC_BIN ?? ZNTC_BIN,
      [
        '--bundle',
        join(dir, 'entry.mjs'),
        '--format=' + format,
        '--target=' + target,
        '--platform=node',
        '--tsconfig-raw={}',
        '--keep-names',
        ...(preserve
          ? [
              '--preserve-modules',
              '--preserve-modules-root=' + dir,
              '--out-extension:.js=.mjs',
              '--outdir',
              outdir,
            ]
          : ['-o', outfile]),
        ...(minify ? ['--minify'] : []),
      ],
      { cwd: dir, encoding: 'utf8', timeout: 30_000 },
    );
    expect(result.error).toBeUndefined();
    return { cli: result, api: null };
  }
  const result = surface === 'sync' ? buildSync(options) : await build(options);
  return { cli: null, api: result };
}
function expectSuccess(result: Awaited<ReturnType<typeof compile>>) {
  if (result.cli) expect(result.cli.status, result.cli.stderr).toBe(0);
  else expect(result.api!.errors, JSON.stringify(result.api!.errors)).toHaveLength(0);
}
beforeAll(() => {
  if (process.env.ZNTC_TEST_CLI_ONLY !== '1') init(process.env.ZNTC_NAPI_PATH);
});
afterAll(() => close());

describe('single-file async module boundaries (#6959)', () => {
  for (const surface of surfaces)
    for (const minify of modes)
      for (const dynamic of [false, true])
        test(`${surface} entry namespace identity diagnostic dynamic=${dynamic} minify=${minify}`, async () => {
          const sentinel = '// existing entry must survive\n';
          const fixture = await createFixture({
            'entry.mjs': dynamic
              ? "await using resource=null;export async function namespace(){return import('./entry.mjs')}"
              : "import*as self from'./entry.mjs';await using resource=null;export function namespace(){return self}",
            'observer.mjs': "import*as ns from'./entry.mjs';console.log(await ns.namespace()===ns)",
            'dist/entry.mjs': sentinel,
          });
          try {
            const native = execute(join(fixture.dir, 'observer.mjs'), fixture.dir);
            expect(native.status, native.stderr).toBe(0);
            expect(native.stdout).toBe('true\n');
            const result = await compile(surface, fixture.dir, minify, false);
            if (result.cli) {
              expect(result.cli.status).not.toBe(0);
              expect(result.cli.stderr).toContain('ZNTC0001');
            } else {
              expect(
                result.api!.errors.some((error) => error.code === 'top_level_await_target'),
              ).toBe(true);
              expect(result.api!.outputFiles).toHaveLength(0);
            }
            expect(readFileSync(join(fixture.dir, 'dist', 'entry.mjs'), 'utf8')).toBe(sentinel);
          } finally {
            await fixture.cleanup();
          }
        });
  for (const surface of surfaces)
    for (const minify of modes)
      for (const input of inputs)
        test(`${surface} single minify=${minify}: ${input.name}`, async () => {
          const fixture = await createFixture({
            'log.mjs': 'export const events=[];',
            'entry.mjs': input.entry,
            'lib.mjs': input.lib,
            'peer.mjs': input.peer ?? 'export {};',
          });
          try {
            let original = join(fixture.dir, 'entry.mjs');
            let emitted = join(fixture.dir, 'dist', 'entry.mjs');
            if (input.consumer) {
              original = join(fixture.dir, 'native-consumer.mjs');
              emitted = join(fixture.dir, 'output-consumer.mjs');
              writeFileSync(original, input.consumer.replace('ENTRY', 'entry.mjs'));
              writeFileSync(emitted, input.consumer.replace('ENTRY', 'dist/entry.mjs'));
            }
            const native = execute(original, fixture.dir);
            expect(native.error).toBeUndefined();
            expect(native.status, native.stderr).toBe(0);
            expect(native.stdout.length).toBeGreaterThan(0);
            if (input.specStdout) {
              // Keep this engine observation explicit; it is not the bundle's
              // expected cleanup and never authorizes dropping the sync call.
              expect(native.stdout).toBe(
                nodeVersion === 'v26.9.0' ? input.node269ObservedStdout! : input.specStdout,
              );
            }
            const result = await compile(surface, fixture.dir, minify, false);
            expectSuccess(result);
            if (result.api) expect(result.api.outputFiles).toHaveLength(1);
            expect(existsSync(join(fixture.dir, 'dist', 'lib.mjs'))).toBe(false);
            const actual = execute(emitted, fixture.dir);
            expect(actual.error).toBeUndefined();
            expect(actual.status, actual.stderr).toBe(native.status);
            expect(actual.stdout).toBe(input.specStdout ?? native.stdout);
            expect(actual.stderr).toBe(native.stderr);
          } finally {
            await fixture.cleanup();
          }
        });
});
