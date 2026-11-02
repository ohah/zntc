import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { build, close, init } from '../../../packages/core/index';
import { createFixture, runZntc } from './helpers';

// Exercise the *external* library consumer, rather than an importer inside the
// bundle. A successful build and eventual side effects do not prove readiness.
// Keep tla-non-esm-formats-4598 and the #5564 export-initializer diagnostics intact.
const formats = ['cjs', 'iife', 'umd'] as const;
const targets = ['es2022', 'es2017', 'es5'] as const;
const surfaces = ['cli', 'napi'] as const;
const minifiers = ['identifiers', 'full'] as const;
type Format = (typeof formats)[number];
type Target = (typeof targets)[number];
type Surface = (typeof surfaces)[number];
type Minifier = (typeof minifiers)[number] | 'plain';
type ExportMode = 'auto' | 'named' | 'default' | 'none';
type Shape = 'named' | 'default';

function librarySource(shape: Shape, asynchronous: boolean, reject = false): string {
  const body = `
const Promise = {tag: 'source-Promise'};
const exports = {tag: 'source-exports'};
const module = {tag: 'source-module'};
globalThis.__events.push('start');
let late = 0;
${asynchronous ? 'late = await globalThis.__gate;' : 'late = 42;'}
${reject ? "throw new Error('late-rejection');" : ''}
globalThis.__events.push('ready');
const answer = {value: late, shadows: [Promise.tag, exports.tag, module.tag]};
`;
  return (
    body +
    (shape === 'default'
      ? 'export default answer;'
      : `
export {late};
export function update() { late++; }
const proto = 'own-proto';
const quoted = 'quoted-value';
const then = 7;
export {proto as '__proto__', quoted as 'quoted-key', then};
export default answer;
`)
  );
}

async function bundle(
  dir: string,
  surface: Surface,
  format: Format,
  target: Target,
  minifier: Minifier,
  mode: ExportMode,
  splitting = false,
  preserveModules = false,
): Promise<string> {
  const out = join(dir, 'dist', 'entry.js');
  if (surface === 'cli') {
    const args = [
      '--bundle',
      join(dir, 'entry.mjs'),
      `--format=${format}`,
      `--target=${target}`,
      '--platform=node',
      '--global-name=ReadyLibrary',
      `--output-exports=${mode}`,
      ...(minifier === 'full'
        ? ['--minify']
        : minifier === 'identifiers'
          ? ['--minify-identifiers']
          : []),
      ...(splitting ? ['--splitting'] : []),
      ...(preserveModules ? ['--preserve-modules', `--preserve-modules-root=${dir}`] : []),
      ...(splitting || preserveModules ? ['--outdir', join(dir, 'dist')] : ['-o', out]),
    ];
    const result = await runZntc(args);
    expect(result.exitCode, result.stderr).toBe(0);
  } else {
    const result = await build({
      entryPoints: [join(dir, 'entry.mjs')],
      rootDir: dir,
      ...(splitting || preserveModules ? { outdir: join(dir, 'dist') } : { outfile: out }),
      write: true,
      format,
      target,
      platform: 'node',
      splitting,
      preserveModules,
      ...(preserveModules ? { preserveModulesRoot: dir } : {}),
      globalName: 'ReadyLibrary',
      outputExports: mode,
      minifyIdentifiers: minifier !== 'plain',
      minifySyntax: minifier === 'full',
      minifyWhitespace: minifier === 'full',
    });
    expect(result.errors ?? [], JSON.stringify(result.errors)).toHaveLength(0);
  }
  // Reading the actual emitted file prevents a missing-output/native-source pass.
  expect(readFileSync(out, 'utf8').length).toBeGreaterThan(0);
  return out;
}

function consume(
  out: string,
  format: Format,
  options: {
    asynchronous: boolean;
    reject?: boolean;
    value: boolean;
    none?: boolean;
    named?: boolean;
    split?: boolean;
    esModule?: boolean;
    observeStart?: boolean;
  },
): void {
  const script = `
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
(async () => {
  let release;
  const events = [];
  let signalStarted;
  const started = new Promise(resolve => { signalStarted = resolve; });
  Object.defineProperty(events, 'push', {
    enumerable: false,
    value: function(...items) {
      const length = Array.prototype.push.apply(this, items);
      if (items.includes('start')) signalStarted();
      return length;
    },
  });
  const gate = new Promise(resolve => { release = resolve; });
  const unhandled = [];
  process.on('unhandledRejection', error => unhandled.push(String(error)));
  globalThis.__events = events;
  globalThis.__gate = gate;
  let output;
  if (${JSON.stringify(format)} === 'cjs') {
    output = require(${JSON.stringify(out)});
  } else {
    const context = vm.createContext({__events: events, __gate: gate, console, setTimeout});
    vm.runInContext(fs.readFileSync(${JSON.stringify(out)}, 'utf8'), context, {filename: 'library.js'});
    output = context.ReadyLibrary;
  }
  const asynchronous = ${options.asynchronous};
  const none = ${!!options.none};
  const isPromise = output != null && typeof output.then === 'function';
  assert.equal(isPromise, asynchronous && !none, 'external readiness ABI');
  if (asynchronous) {
    // Observe completion before waiting for a provider's actual start. PM may
    // schedule evaluation after require() returns; no timing delay is assumed.
    let didSettle = false;
    const settled = !none ? Promise.resolve(output).then(
      value => { didSettle = true; return {value}; },
      error => { didSettle = true; return {error}; },
    ) : null;
    if (${!!options.observeStart}) {
      await started;
      assert.equal(didSettle, false, 'actual provider start must precede readiness');
    }
    assert.deepEqual(events, ['start'], 'must suspend before readiness');
    release(42);
    if (${!!options.reject}) {
      const result = await settled;
      assert.equal(result.error.message, 'late-rejection');
      assert.deepEqual(events, ['start']);
      await new Promise(resolve => setImmediate(resolve));
      assert.deepEqual(unhandled, [], 'awaited rejection must not leak');
      console.log('rejected');
      return;
    }
    if (!none) {
      const result = await settled;
      assert.equal(result.error, undefined);
      output = result.value;
    } else {
      await new Promise(resolve => setImmediate(resolve));
    }
  }
  assert.deepEqual(events, ['start', 'ready']);
  assert.deepEqual(unhandled, []);
  if (none) {
    assert.deepEqual(Object.keys(output), [], 'CJS none keeps its no-export ABI');
  } else {
    if (${!!options.esModule}) {
      const marker = Object.getOwnPropertyDescriptor(output, '__esModule');
      assert.equal(marker.value, true);
      assert.equal(marker.enumerable, false, 'synthetic interop marker must be nonenumerable');
      assert.equal(marker.get, undefined, 'synthetic interop marker is a data property');
    }
    const value = ${options.value} ? output : output.default;
    assert.equal(value.value, 42);
    assert.equal(JSON.stringify(value.shadows), JSON.stringify(['source-Promise', 'source-exports', 'source-module']));
    if (${!!options.named}) {
      assert.equal(output.late, 42);
      const getter = Object.getOwnPropertyDescriptor(output, 'late').get;
      assert.equal(typeof getter, 'function');
      output.update();
      assert.equal(output.late, 43, 'namespace remains live after readiness');
      assert.equal(output.default.value, 42, 'default value remains its snapshot');
      assert.equal(Object.prototype.hasOwnProperty.call(output, '__proto__'), true);
      assert.equal(output['__proto__'], 'own-proto');
      assert.equal(output['quoted-key'], 'quoted-value');
      assert.equal(output.then, 7, 'noncallable then is an ordinary namespace key');
      if (${!!options.split}) assert.equal((await output.load()).late, 43, 'actual cross-chunk consumer sees live updates');
    }
  }
  console.log('ready');
})().catch(error => { console.error(error); process.exitCode = 1; });
`;
  const child = spawnSync('node', ['--unhandled-rejections=strict', '-e', script], {
    encoding: 'utf8',
    timeout: 10000,
  });
  expect(child.error, child.stderr).toBeUndefined();
  expect(child.status, child.stderr).toBe(0);
  expect(child.stdout).toBe(options.reject ? 'rejected\n' : 'ready\n');
}

describe('TLA library external readiness and existing export ABI (#4598)', () => {
  beforeAll(() => init());
  afterAll(() => close());
  for (const surface of surfaces)
    for (const format of formats)
      for (const target of targets)
        for (const minifier of minifiers) {
          const label = `${surface} ${format} ${target} ${minifier}`;
          for (const scenario of [
            { name: 'mixed namespace auto', shape: 'named', mode: 'auto' },
            { name: 'default-only auto', shape: 'default', mode: 'auto' },
            { name: 'default-only named', shape: 'default', mode: 'named' },
            { name: 'default-only default', shape: 'default', mode: 'default' },
            { name: 'explicit none', shape: 'named', mode: 'none' },
          ] as const) {
            test(`${label}: ${scenario.name} awaits late values`, async () => {
              const fixture = await createFixture({
                'entry.mjs': librarySource(scenario.shape, true),
              });
              try {
                const out = await bundle(
                  fixture.dir,
                  surface,
                  format,
                  target,
                  minifier,
                  scenario.mode,
                );
                consume(out, format, {
                  asynchronous: true,
                  value:
                    format === 'cjs' && scenario.shape === 'default' && scenario.mode !== 'named',
                  none: format === 'cjs' && scenario.mode === 'none',
                  named:
                    scenario.shape === 'named' && !(format === 'cjs' && scenario.mode === 'none'),
                  esModule:
                    format === 'cjs' &&
                    (scenario.mode === 'named' ||
                      (scenario.shape === 'named' && scenario.mode === 'auto')),
                });
              } finally {
                await fixture.cleanup();
              }
            });
          }
          test(`${label}: external awaited rejection has no unhandled rejection`, async () => {
            const fixture = await createFixture({
              'entry.mjs': librarySource('named', true, true),
            });
            try {
              const out = await bundle(fixture.dir, surface, format, target, minifier, 'auto');
              consume(out, format, { asynchronous: true, reject: true, value: false });
            } finally {
              await fixture.cleanup();
            }
          });
          for (const mode of ['auto', 'named', 'default', 'none'] as const) {
            test(`${label}: synchronous ${mode} keeps its synchronous ABI`, async () => {
              const fixture = await createFixture({ 'entry.mjs': librarySource('default', false) });
              try {
                const out = await bundle(fixture.dir, surface, format, target, minifier, mode);
                consume(out, format, {
                  asynchronous: false,
                  value: format === 'cjs' && mode !== 'named',
                  none: format === 'cjs' && mode === 'none',
                });
              } finally {
                await fixture.cleanup();
              }
            });
          }
        }
});

// A static PM-CJS provider and a shared async ESM provider exercise the consumer
// boundary too. In the split case, assert real separate output files; a
// single-chunk build is not evidence for cross-chunk readiness.
describe('TLA library PM-CJS and real split consumers (#4598)', () => {
  beforeAll(() => init());
  afterAll(() => close());
  for (const surface of surfaces)
    for (const target of targets)
      for (const minifier of minifiers)
        for (const split of [false, true]) {
          test(`${surface} cjs ${target} ${minifier} ${split ? 'real split' : 'PM-CJS'}`, async () => {
            const fixture = await createFixture({
              'provider.cjs': 'module.exports = {seed: 42};',
              'shared.mjs': `import provider from './provider.cjs';
globalThis.__events.push('start');
export let late = 0;
await globalThis.__gate;
late = provider.seed;
globalThis.__events.push('ready');
export function update() { late++; }`,
              'lazy.mjs': "export {late} from './shared.mjs';",
              'entry.mjs': `import {late, update} from './shared.mjs';
export {late, update};
const Promise = {tag: 'source-Promise'};
const exports = {tag: 'source-exports'};
const module = {tag: 'source-module'};
export default {value: late, shadows: [Promise.tag, exports.tag, module.tag]};
const proto = 'own-proto', quoted = 'quoted-value', then = 7;
export {proto as '__proto__', quoted as 'quoted-key', then};
${split ? "export function load() { return import('./lazy.mjs'); }" : ''}`,
            });
            try {
              const out = await bundle(
                fixture.dir,
                surface,
                'cjs',
                target,
                minifier,
                'auto',
                split,
                !split,
              );
              {
                const files = readdirSync(join(fixture.dir, 'dist'), { recursive: true }).filter(
                  (path) => String(path).endsWith('.js'),
                );
                expect(files.length, 'must emit separate entry/provider files').toBeGreaterThan(2);
                expect(files.map(String)).toContain('entry.js');
                if (!split) {
                  expect(files.map(String)).toContain('shared.js');
                  expect(files.map(String)).toContain('provider.js');
                }
              }
              consume(out, 'cjs', {
                asynchronous: true,
                value: false,
                named: true,
                split,
                observeStart: true,
              });
            } finally {
              await fixture.cleanup();
            }
          });
        }
});

// Callable `then` cannot be made an ordinary key by a special library Promise:
// resolve-to-namespace follows the same assimilation semantics as native import.
describe('TLA library callable then follows native namespace assimilation (#4598)', () => {
  beforeAll(() => init());
  afterAll(() => close());
  for (const surface of surfaces)
    for (const format of formats)
      for (const target of targets)
        for (const minifier of minifiers) {
          test(`${surface} ${format} ${target} ${minifier}`, async () => {
            const fixture = await createFixture({
              'entry.mjs': `await globalThis.__gate;
export function then(resolve) { resolve('assimilated-42'); }
export const late = 42;`,
            });
            try {
              const native = spawnSync(
                'node',
                [
                  '--input-type=module',
                  '-e',
                  `
globalThis.__gate = Promise.resolve();
const value = await import(${JSON.stringify('file://')} + ${JSON.stringify(join(fixture.dir, 'entry.mjs'))});
console.log(JSON.stringify(value));`,
                ],
                { encoding: 'utf8', timeout: 10000 },
              );
              expect(native.status, native.stderr).toBe(0);
              expect(native.stdout).toBe('"assimilated-42"\n');
              const out = await bundle(fixture.dir, surface, format, target, minifier, 'auto');
              const run = spawnSync(
                'node',
                [
                  '--unhandled-rejections=strict',
                  '-e',
                  `
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
(async () => {
  let release;
  globalThis.__gate = new Promise(resolve => {release = resolve;});
  let output;
  if (${JSON.stringify(format)} === 'cjs') output = require(${JSON.stringify(out)});
  else {
    const context = vm.createContext({__gate: globalThis.__gate});
    vm.runInContext(fs.readFileSync(${JSON.stringify(out)}, 'utf8'), context);
    output = context.ReadyLibrary;
  }
  assert.equal(typeof output.then, 'function');
  let settled = false;
  const result = output.then(value => {settled = true; return value;});
  assert.equal(settled, false);
  release();
  console.log(JSON.stringify(await result));
})().catch(error => {console.error(error); process.exitCode = 1;});`,
                ],
                { encoding: 'utf8', timeout: 10000 },
              );
              expect(run.error, run.stderr).toBeUndefined();
              expect(run.status, run.stderr).toBe(0);
              expect(run.stdout).toBe(native.stdout);
            } finally {
              await fixture.cleanup();
            }
          });
        }
});

// outputExports=none deliberately has no readiness return value. Preserve its
// existing uncaught-rejection behavior rather than silently installing a Promise.
describe('TLA CJS none keeps rejection behavior (#4598)', () => {
  beforeAll(() => init());
  afterAll(() => close());
  for (const surface of surfaces)
    for (const target of targets)
      for (const minifier of minifiers) {
        test(`${surface} ${target} ${minifier}`, async () => {
          const fixture = await createFixture({
            'entry.mjs': librarySource('default', true, true),
          });
          try {
            const out = await bundle(fixture.dir, surface, 'cjs', target, minifier, 'none');
            const run = spawnSync(
              'node',
              [
                '--unhandled-rejections=strict',
                '-e',
                `
const assert = require('node:assert/strict');
globalThis.__events = [];
globalThis.__gate = Promise.resolve(42);
const output = require(${JSON.stringify(out)});
assert.equal(typeof output.then, 'undefined');
assert.deepEqual(Object.keys(output), []);`,
              ],
              { encoding: 'utf8', timeout: 10000 },
            );
            expect(run.error, run.stderr).toBeUndefined();
            expect(run.status).not.toBe(0);
            expect(run.stderr).toContain('late-rejection');
          } finally {
            await fixture.cleanup();
          }
        });
      }
});

function consumePublicAbi(out: string, scenario: 'marker' | 'public-marker' | 'value'): void {
  const script = `
const assert = require('node:assert/strict');
(async () => {
  let release;
  globalThis.__gate = new Promise(resolve => {release = resolve;});
  const ready = require(${JSON.stringify(out)});
  assert.equal(typeof ready.then, 'function');
  const completion = ready.then(value => value);
  release(42);
  const value = await completion;
  if (${JSON.stringify(scenario)} === 'value') assert.equal(value, 42);
  else {
    assert.equal(value.default, 42);
    const marker = Object.getOwnPropertyDescriptor(value, '__esModule');
    assert.ok(marker, 'public interop descriptor exists');
    if (${JSON.stringify(scenario)} === 'marker') {
      assert.equal(marker.value, true);
      assert.equal(marker.get, undefined);
      assert.equal(marker.enumerable, false);
    } else {
      assert.equal(value.__esModule, 'real-public-marker');
      assert.equal(marker.enumerable, true, 'a real ESM public export remains enumerable');
    }
  }
  console.log('public-abi-ready');
})().catch(error => {console.error(error); process.exitCode = 1;});`;
  const run = spawnSync('node', ['--unhandled-rejections=strict', '-e', script], {
    encoding: 'utf8',
    timeout: 10000,
  });
  expect(run.error, run.stderr).toBeUndefined();
  expect(run.status, run.stderr).toBe(0);
  expect(run.stdout).toBe('public-abi-ready\n');
}

describe('TLA library additional public ABI (#4598)', () => {
  beforeAll(() => init());
  afterAll(() => close());
  for (const surface of surfaces)
    for (const target of targets)
      for (const minifier of minifiers) {
        for (const named of [false, true]) {
          test(`${surface} cjs ${target} ${minifier}: synthetic marker descriptor ${named ? 'mixed auto' : 'default named'}`, async () => {
            const fixture = await createFixture({
              'entry.mjs': `let value = 0;
value = await globalThis.__gate;
export {value as default};
${named ? 'export const marker = 7;' : ''}`,
            });
            try {
              const out = await bundle(
                fixture.dir,
                surface,
                'cjs',
                target,
                minifier,
                named ? 'auto' : 'named',
              );
              consumePublicAbi(out, 'marker');
            } finally {
              await fixture.cleanup();
            }
          });
        }
        test(`${surface} cjs ${target} ${minifier}: real quoted __esModule is preserved`, async () => {
          const fixture = await createFixture({
            'entry.mjs': `let value = 0;
value = await globalThis.__gate;
const publicMarker = 'real-public-marker';
export {publicMarker as '__esModule'};
export {value as default};`,
          });
          try {
            const out = await bundle(fixture.dir, surface, 'cjs', target, minifier, 'auto');
            consumePublicAbi(out, 'public-marker');
          } finally {
            await fixture.cleanup();
          }
        });
        test(`${surface} cjs ${target} ${minifier}: quoted default alias auto returns the value`, async () => {
          const fixture = await createFixture({
            'entry.mjs': `let value = 0;
value = await globalThis.__gate;
export {value as 'default'};`,
          });
          try {
            const out = await bundle(fixture.dir, surface, 'cjs', target, minifier, 'auto');
            consumePublicAbi(out, 'value');
          } finally {
            await fixture.cleanup();
          }
        });
      }
  for (const surface of surfaces)
    for (const minifier of ['plain', 'identifiers', 'full'] as const) {
      test(`${surface} cjs es2022 ${minifier}: source Object does not capture runtime intrinsics`, async () => {
        const fixture = await createFixture({
          'entry.mjs': `const Object = {tag: 42};
let value = 0;
await globalThis.__gate;
value = Object.tag;
export {value as default};`,
        });
        try {
          const out = await bundle(fixture.dir, surface, 'cjs', 'es2022', minifier, 'auto');
          consumePublicAbi(out, 'value');
        } finally {
          await fixture.cleanup();
        }
      });
    }
});

// Preserve the exact extra-split-v10 inputs: a TLA provider must finish before
// an internal consumer snapshots its import; dynamic import must return a
// namespace even when a default-only CJS library would return its default value.
const internalAsyncConsumerCases = {
  'internal-consumer': {
    'consumer.mjs': 'import {value} from "./slow.mjs";export const combined=value;',
    'entry.mjs':
      'import {combined} from "./consumer.mjs";export {combined};export function load(){return import("./lazy.mjs")}',
    'lazy.mjs': 'export {combined} from "./consumer.mjs";',
    'slow.mjs': 'export let value=0;await new Promise(r=>setTimeout(r,5));value=42;',
  },
  'dynamic-default': {
    'entry.mjs': 'export function load(){return import("./lazy.mjs")}',
    'lazy.mjs': 'await new Promise(r=>setTimeout(r,5));const value=42;export default value;',
  },
} as const;

describe('TLA library internal common consumer and dynamic default namespace (#4598)', () => {
  beforeAll(() => init());
  afterAll(() => close());
  for (const surface of surfaces)
    for (const minifier of minifiers)
      for (const scenario of ['internal-consumer', 'dynamic-default'] as const) {
        test(`${surface} cjs es2017 ${minifier}: ${scenario}`, async () => {
          const fixture = await createFixture({ ...internalAsyncConsumerCases[scenario] });
          try {
            const observe =
              scenario === 'internal-consumer'
                ? `const value = await entry; const lazy = await value.load(); console.log(JSON.stringify({combined:value.combined,lazy:lazy.combined}));`
                : `assert.equal(typeof entry.then, 'undefined', 'dynamic-only entry keeps synchronous ABI'); const lazy = await entry.load(); assert.equal(Object.prototype.hasOwnProperty.call(lazy, 'default'), true); console.log(JSON.stringify({keys:Object.keys(lazy),value:lazy.default}));`;
            const expected =
              scenario === 'internal-consumer'
                ? { combined: 42, lazy: 42 }
                : { keys: ['default'], value: 42 };
            const native = spawnSync(
              'node',
              [
                '--input-type=module',
                '-e',
                `
import assert from 'node:assert/strict';
const entry = await import(${JSON.stringify(pathToFileURL(join(fixture.dir, 'entry.mjs')).href)});
${observe}`,
              ],
              { encoding: 'utf8', timeout: 10000 },
            );
            expect(native.error, native.stderr).toBeUndefined();
            expect(native.status, native.stderr).toBe(0);
            expect(JSON.parse(native.stdout)).toEqual(expected);

            const out = await bundle(fixture.dir, surface, 'cjs', 'es2017', minifier, 'auto', true);
            const files = readdirSync(join(fixture.dir, 'dist'), { recursive: true }).filter(
              (path) => String(path).endsWith('.js'),
            );
            expect(
              files.length,
              'actual entry, lazy and provider/helper output files are required',
            ).toBeGreaterThan(2);
            expect(files.map(String)).toContain('entry.js');
            expect(files.some((path) => String(path).includes('lazy'))).toBe(true);
            const bundled = spawnSync(
              'node',
              [
                '--unhandled-rejections=strict',
                '-e',
                `
const assert = require('node:assert/strict');
(async () => {
  const entry = require(${JSON.stringify(out)});
  ${scenario === 'internal-consumer' ? "assert.equal(typeof entry.then, 'function', 'async static dependency exposes entry readiness');" : ''}
  ${observe}
})().catch(error => {console.error(error); process.exitCode = 1;});`,
              ],
              { encoding: 'utf8', timeout: 10000 },
            );
            expect(bundled.error, bundled.stderr).toBeUndefined();
            expect(bundled.status, bundled.stderr).toBe(0);
            expect(bundled.stdout).toBe(native.stdout);
          } finally {
            await fixture.cleanup();
          }
        });
      }
});

// `none` suppresses the external entry export, not dependency evaluation. Its
// require() result stays {}, and a rejected detached evaluation keeps the
// existing strict-unhandled behavior instead of installing a public Promise.
describe('TLA library split CJS none preserves side effects and rejection (#4598)', () => {
  beforeAll(() => init());
  afterAll(() => close());
  for (const surface of surfaces)
    for (const minifier of minifiers)
      for (const reject of [false, true]) {
        test(`${surface} cjs es2017 ${minifier}: ${reject ? 'rejected' : 'successful'} none split`, async () => {
          const fixture = await createFixture({
            'slow.mjs': `globalThis.__events.push('start');
export let value = 0;
await globalThis.__gate;
${reject ? "throw new Error('none-split-rejection');" : "value = 42; globalThis.__events.push('ready');"}`,
            'consumer.mjs': "import {value} from './slow.mjs'; export const snapshot = value;",
            'entry.mjs': `import {snapshot} from './consumer.mjs';
globalThis.__value = snapshot;
globalThis.__events.push('consumer');
globalThis.__load = () => import('./lazy.mjs');`,
            'lazy.mjs': `import {snapshot} from './consumer.mjs';
globalThis.__lazyValue = snapshot;
globalThis.__events.push('lazy');`,
          });
          try {
            const observer = `
let release, signalStarted, signalConsumer;
const events = [];
const started = new Promise(resolve => {signalStarted = resolve;});
const consumer = new Promise(resolve => {signalConsumer = resolve;});
Object.defineProperty(events, 'push', {enumerable:false, value:function(...items) {
  const length = Array.prototype.push.apply(this, items);
  if (items.includes('start')) signalStarted();
  if (items.includes('consumer')) signalConsumer();
  return length;
}});
globalThis.__events = events;
globalThis.__gate = new Promise(resolve => {release = resolve;});`;
            const nativeScript = `
import assert from 'node:assert/strict';
${observer}
let settled = false;
const pending = import(${JSON.stringify(pathToFileURL(join(fixture.dir, 'entry.mjs')).href)})
  .then(ns => {settled = true; return {ns};}, error => {settled = true; return {error};});
await started;
assert.equal(settled, false);
assert.deepEqual(events, ['start']);
release(42);
const result = await pending;
${
  reject
    ? `assert.equal(result.error.message, 'none-split-rejection');
assert.equal(globalThis.__value, undefined);
console.log(JSON.stringify({events, reason:result.error.message, noConsumer:true}));`
    : `assert.equal(result.error, undefined);
await consumer;
await globalThis.__load();
console.log(JSON.stringify({events,value:globalThis.__value,lazy:globalThis.__lazyValue,entryKeys:Object.keys(result.ns),entryThen:typeof result.ns.then}));`
}`;
            const native = spawnSync(
              'node',
              ['--input-type=module', '--unhandled-rejections=strict', '-e', nativeScript],
              { encoding: 'utf8', timeout: 10000 },
            );
            expect(native.error, native.stderr).toBeUndefined();
            expect(native.status, native.stderr).toBe(0);
            const expected = reject
              ? { events: ['start'], reason: 'none-split-rejection', noConsumer: true }
              : {
                  events: ['start', 'ready', 'consumer', 'lazy'],
                  value: 42,
                  lazy: 42,
                  entryKeys: [],
                  entryThen: 'undefined',
                };
            expect(JSON.parse(native.stdout)).toEqual(expected);

            const out = await bundle(fixture.dir, surface, 'cjs', 'es2017', minifier, 'none', true);
            const files = readdirSync(join(fixture.dir, 'dist'), { recursive: true }).filter(
              (path) => String(path).endsWith('.js'),
            );
            expect(
              files.length,
              'none must exercise actual entry/lazy/shared output files',
            ).toBeGreaterThan(2);
            expect(files.map(String)).toContain('entry.js');
            expect(files.some((path) => String(path).includes('lazy'))).toBe(true);
            const script = `
const assert = require('node:assert/strict');
(async () => {
${observer}
let entry;
${
  reject
    ? `process.on('uncaughtExceptionMonitor', error => {
  console.log(JSON.stringify({events, reason:error.message, noConsumer:globalThis.__value === undefined}));
});`
    : ''
}
entry = require(${JSON.stringify(out)});
assert.deepEqual(Object.keys(entry), [], 'none exposes no entry exports');
assert.equal(typeof entry.then, 'undefined', 'none never installs a public Promise');
await started;
assert.deepEqual(events, ['start']);
release(42);
${
  reject
    ? ''
    : `await consumer;
await globalThis.__load();
assert.deepEqual(Object.keys(entry), []);
assert.equal(typeof entry.then, 'undefined');
console.log(JSON.stringify({events,value:globalThis.__value,lazy:globalThis.__lazyValue,entryKeys:Object.keys(entry),entryThen:typeof entry.then}));`
}
})().catch(error => {console.error(error); process.exitCode = 1;});`;
            const child = spawnSync('node', ['--unhandled-rejections=strict', '-e', script], {
              encoding: 'utf8',
              timeout: 10000,
            });
            expect(child.error, child.stderr).toBeUndefined();
            if (reject) {
              expect(child.status).not.toBe(0);
              expect(child.stderr).toContain('none-split-rejection');
            } else {
              expect(child.status, child.stderr).toBe(0);
            }
            expect(JSON.parse(child.stdout)).toEqual(expected);
          } finally {
            await fixture.cleanup();
          }
        });
      }
});
