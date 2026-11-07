import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { buildSync, close, init } from '../../../packages/core/index';
import { createFixture, ZNTC_BIN } from './helpers';

// #4740: each dependency module owns its synchronous using lifetime. Compare
// actual Node module evaluation, not just the bundle's eventual side effects.
// Asynchronous disposal timing is tracked separately. The mixed await/sync
// case below checks only its already-supported exported value, not timing.
// CLI-only is an explicit baseline cohort, never a skipped NAPI pass.
const cliOnly = process.env.ZNTC_TEST_CLI_ONLY === '1';
const surfaces: readonly ('cli' | 'napi')[] = cliOnly ? ['cli'] : ['cli', 'napi'];
const modes = ['plain', 'identifiers', 'full'] as const;
type DisposalCase = {
  name: string;
  files: Record<string, string>;
  expected?: unknown;
  expectedText?: string;
};

const cases: DisposalCase[] = [
  {
    name: 'original-module-exports',
    files: {
      'main.mjs': `import d, { g, k, C } from './lib.mjs';
console.log(g(), k, C.v, d, globalThis.LOG.join());
`,
      'lib.mjs': `const log = (globalThis.LOG = []);
const R = (n) => ({
  [Symbol.dispose]() {
    log.push('d' + n);
  },
});
export function g() {
  return 'g' + k;
}
using a = R(1);
export const k = 1;
export class C {
  static v = 2;
}
export default 7;
`,
    },
    expectedText: 'g1 1 2 7 d1\n',
  },
  {
    name: '01-dependency-boundary',
    files: {
      'log.mjs': `export const events = [];
`,
      'lib.mjs': `import { events } from './log.mjs';
using resource = { [Symbol.dispose]() { events.push('dep-dispose'); } };
events.push('dep-body');
export const answer = 42;
`,
      'main.mjs': `import { events } from './log.mjs';
import { answer } from './lib.mjs';
events.push('entry');
console.log(JSON.stringify([answer, events]));
`,
    },
    expected: [42, ['dep-body', 'dep-dispose', 'entry']],
  },
  {
    name: '02-resource-lifo',
    files: {
      'log.mjs': `export const events = [];
`,
      'lib.mjs': `import { events } from './log.mjs';
using first = { [Symbol.dispose]() { events.push('dispose-first'); } };
using second = { [Symbol.dispose]() { events.push('dispose-second'); } };
events.push('body');
export const answer = 42;
`,
      'main.mjs': `import { events } from './log.mjs';
import { answer } from './lib.mjs';
console.log(JSON.stringify([answer, events]));
`,
    },
    expected: [42, ['body', 'dispose-second', 'dispose-first']],
  },
  {
    name: '03-two-module-order',
    files: {
      'log.mjs': `export const events = [];
`,
      'alpha.mjs': `import { events } from './log.mjs';
using resource = { [Symbol.dispose]() { events.push('alpha-dispose'); } };
events.push('alpha-body');
export const answer = 40;
`,
      'bravo.mjs': `import { events } from './log.mjs';
import { answer } from './alpha.mjs';
using resource = { [Symbol.dispose]() { events.push('bravo-dispose'); } };
events.push('bravo-body:' + answer);
export const result = answer + 2;
`,
      'main.mjs': `import { events } from './log.mjs';
import { result } from './bravo.mjs';
console.log(JSON.stringify([result, events]));
`,
    },
    expected: [42, ['alpha-body', 'alpha-dispose', 'bravo-body:40', 'bravo-dispose']],
  },
  {
    name: '04-live-default-class-exports',
    files: {
      'log.mjs': `export const events = [];
`,
      'lib.mjs': `import { events } from './log.mjs';
export let answer = 41;
using resource = { [Symbol.dispose]() { answer++; events.push('dispose:' + answer); } };
export function read() { return answer; }
export class Named { static answer = 42; }
export default Named;
events.push('body:' + answer);
`,
      'main.mjs': `import DefaultClass, { answer, read, Named } from './lib.mjs';
import { events } from './log.mjs';
console.log(JSON.stringify([answer, read(), DefaultClass === Named, Named.name, Named.answer, events]));
`,
    },
    expected: [42, 42, true, 'Named', 42, ['body:41', 'dispose:42']],
  },
  {
    name: '05-cycle-deferred-read',
    files: {
      'log.mjs': `export const events = [];
`,
      'alpha.mjs': `import { events } from './log.mjs';
import { readAlpha } from './bravo.mjs';
using resource = { [Symbol.dispose]() { events.push('alpha-dispose'); } };
export let marker = 'A';
events.push('alpha-ready');
readAlpha();
`,
      'bravo.mjs': `import { events } from './log.mjs';
import { marker } from './alpha.mjs';
using resource = { [Symbol.dispose]() { events.push('bravo-dispose'); } };
events.push('bravo-body');
export function readAlpha() { events.push('read:' + marker); }
`,
      'main.mjs': `import { events } from './log.mjs';
import './alpha.mjs';
console.log(JSON.stringify(events));
`,
    },
    expected: ['bravo-body', 'bravo-dispose', 'alpha-ready', 'read:A', 'alpha-dispose'],
  },
  {
    name: '08-body-dispose-suppression',
    files: {
      'log.mjs': `export const events = [];
`,
      'lib.mjs': `import { events } from './log.mjs';
using resource = { [Symbol.dispose]() { events.push('dispose'); throw Error('dispose'); } };
events.push('body');
throw Error('body');
`,
      'main.mjs': `import { events } from './log.mjs';
import('./lib.mjs').then(
  () => console.log('UNEXPECTED_SUCCESS'),
  error => console.log(JSON.stringify([error.name, error.error.message, error.suppressed.message, events])),
);
`,
    },
    expected: ['SuppressedError', 'dispose', 'body', ['body', 'dispose']],
  },
  {
    name: '09-multiple-dispose-errors',
    files: {
      'log.mjs': `export const events = [];
`,
      'lib.mjs': `import { events } from './log.mjs';
using first = { [Symbol.dispose]() { events.push('first'); throw Error('first'); } };
using second = { [Symbol.dispose]() { events.push('second'); throw Error('second'); } };
events.push('body');
throw Error('body');
`,
      'main.mjs': `import { events } from './log.mjs';
function view(error) {
  return error.name === 'SuppressedError'
    ? [error.name, view(error.error), view(error.suppressed)]
    : [error.name, error.message];
}
import('./lib.mjs').then(
  () => console.log('UNEXPECTED_SUCCESS'),
  error => console.log(JSON.stringify([view(error), events])),
);
`,
    },
    expected: [
      [
        'SuppressedError',
        ['Error', 'first'],
        ['SuppressedError', ['Error', 'second'], ['Error', 'body']],
      ],
      ['body', 'second', 'first'],
    ],
  },
  {
    name: '10-disposer-lookup-abrupt',
    files: {
      'log.mjs': `export const events = [];
`,
      'lib.mjs': `import { events } from './log.mjs';
events.push('init-first');
using first = { [Symbol.dispose]() { events.push('dispose-first'); } };
using second = {
  get [Symbol.dispose]() { events.push('lookup-second'); throw Error('lookup'); },
};
events.push('UNREACHABLE');
`,
      'main.mjs': `import { events } from './log.mjs';
import('./lib.mjs').then(
  () => console.log('UNEXPECTED_SUCCESS'),
  error => console.log(JSON.stringify([error.name, error.message, events])),
);
`,
    },
    expected: ['Error', 'lookup', ['init-first', 'lookup-second', 'dispose-first']],
  },
  {
    name: 'healthy-main-using-cycle-tdz',
    files: {
      'main.mjs': `import { early, readAfter } from './peer.mjs';
globalThis.controlEvents = [];
using resource = { value: 42, [Symbol.dispose]() { globalThis.controlEvents.push('dispose'); } };
export { resource };
console.log(JSON.stringify([early, readAfter()]));
`,
      'peer.mjs': `import { resource } from './main.mjs';
let early;
try { resource; early = 'incorrectly-initialized'; } catch (error) { early = error.name; }
export { early };
export function readAfter() { return resource.value; }
`,
    },
    expected: ['ReferenceError', 42],
  },
  {
    name: 'healthy-function-hoist',
    files: {
      'lib.mjs': `using resource = { [Symbol.dispose]() {} };
export const before = hoisted();
export function hoisted() { return 42; }
export const identity = hoisted;
`,
      'main.mjs': `import { before, hoisted, identity } from './lib.mjs';
console.log(JSON.stringify([before, hoisted(), identity === hoisted]));
`,
    },
    expectedText: '[42,42,true]\n',
  },
  {
    name: 'healthy-local-class-TDZ',
    files: {
      'lib.mjs': `using resource = { [Symbol.dispose]() {} };
export function check() {
  let early;
  try { Holder; early = 'incorrectly-initialized'; } catch (error) { early = error.name; }
  class Holder { value = 42; static self() { return Holder; } }
  return [early, new Holder().value, Holder.self() === Holder];
}
`,
      'main.mjs': `import { check } from './lib.mjs';
console.log(JSON.stringify(check()));
`,
    },
    expectedText: '["ReferenceError",42,true]\n',
  },
  {
    name: 'healthy-block-using-exception',
    files: {
      'lib.mjs': `export const events = [];
using outer = { [Symbol.dispose]() {} };
try {
  using first = { [Symbol.dispose]() { events.push('dispose'); } };
  events.push('body');
  throw new Error('failure');
} catch (error) { events.push(error.message); }
`,
      'main.mjs': `import { events } from './lib.mjs';
console.log(JSON.stringify(events));
`,
    },
    expectedText: '["body","dispose","failure"]\n',
  },
  {
    name: 'healthy-live-default-observe-in-place',
    files: {
      'lib.mjs': `export let value = 1;
export default value;
export function advance() { value++; }
using resource = { [Symbol.dispose]() {} };
`,
      'main.mjs': `import initial, { value, advance } from "./lib.mjs";
advance(); console.log(initial, value);
advance(); console.log(initial, value);
`,
    },
    expectedText: '1 2\n1 3\n',
  },
  {
    // Preserve the already-supported mixed-module exported value. This does
    // not assert that asynchronous disposal timing is fixed by #4740.
    name: 'healthy-mixed-await-sync-export-value',
    files: {
      'lib.mjs': `using resource={label:"ok",[Symbol.dispose](){}}; await using other={async [Symbol.asyncDispose](){}}; export {resource};
`,
      'main.mjs': `const {resource}=await import("./lib.mjs"); console.log(resource.label);
`,
    },
    expectedText: 'ok\n',
  },
];

function executeModule(entry: string, cwd: string) {
  return spawnSync(process.env.ZNTC_NODE_BIN ?? 'node', [entry], {
    cwd,
    encoding: 'utf8',
    timeout: 5_000,
  });
}

beforeAll(() => {
  if (!cliOnly) init(process.env.ZNTC_NAPI_PATH);
});
afterAll(() => close());

describe('module native using disposal boundaries (#4740)', () => {
  for (const surface of surfaces) {
    for (const mode of modes) {
      for (const item of cases) {
        test(`${surface} ${mode}: ${item.name}`, async () => {
          const fixture = await createFixture(item.files);
          try {
            const entry = join(fixture.dir, 'main.mjs');
            const native = executeModule(entry, fixture.dir);
            expect(native.error).toBeUndefined();
            expect(native.status, native.stderr).toBe(0);
            expect(native.stderr).toBe('');
            if (item.expectedText !== undefined) expect(native.stdout).toBe(item.expectedText);
            else expect(JSON.parse(native.stdout)).toEqual(item.expected);

            const outfile = join(fixture.dir, 'dist', 'entry.mjs');
            if (surface === 'cli') {
              const flags =
                mode === 'full'
                  ? ['--minify']
                  : mode === 'identifiers'
                    ? ['--minify-identifiers']
                    : [];
              const result = spawnSync(
                process.env.ZNTC_BIN ?? ZNTC_BIN,
                [
                  '--bundle',
                  entry,
                  '--format=esm',
                  '--platform=node',
                  '--target=esnext',
                  '--keep-names',
                  '-o',
                  outfile,
                  ...flags,
                ],
                { cwd: fixture.dir, encoding: 'utf8', timeout: 30_000 },
              );
              expect(result.error).toBeUndefined();
              expect(result.status, result.stderr).toBe(0);
            } else {
              const result = buildSync({
                entryPoints: [entry],
                rootDir: fixture.dir,
                outfile,
                target: 'esnext',
                platform: 'node',
                format: 'esm',
                write: true,
                // The live/default/class witness observes Named.name. Request
                // the documented name-preservation policy on both surfaces.
                keepNames: true,
                minifyIdentifiers: mode !== 'plain',
                minifySyntax: mode === 'full',
                minifyWhitespace: mode === 'full',
              });
              expect(result.errors, JSON.stringify(result.errors)).toHaveLength(0);
            }
            expect(existsSync(outfile)).toBe(true);
            expect(readFileSync(outfile, 'utf8').length).toBeGreaterThan(0);
            const output = executeModule(outfile, fixture.dir);
            expect(output.error).toBeUndefined();
            expect(output.status, output.stderr).toBe(native.status);
            expect(output.stdout).toBe(native.stdout);
            expect(output.stderr).toBe(native.stderr);
          } finally {
            await fixture.cleanup();
          }
        });
      }
    }
  }
});
