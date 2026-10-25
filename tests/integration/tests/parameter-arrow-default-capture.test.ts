import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntcInDir } from './helpers';

const cases: { name: string; source: string; preload?: string; expected?: string }[] = [
  {
    name: 'ordinary function nested in async state machine',
    source: `(async function () {
      function run(value = (() => this.base + arguments.length)()) { return value; }
      console.log(run.call({ base: 3 }));
    })();`,
  },
  {
    name: 'parameter arguments with body this capture',
    source: `
      const host = { base: 9 };
      function run(value = (() => arguments.length)()) {
        return [value, (() => this.base)()];
      }
      console.log(JSON.stringify([run.call(host), run.call(host, 4)]));
    `,
  },
  {
    name: 'parameter this with body arguments capture',
    source: `
      const host = { base: 9 };
      function run(value = (() => this.base)()) {
        return [value, (() => arguments[1])()];
      }
      console.log(JSON.stringify([run.call(host, undefined, 3), run.call(host, 4, 5)]));
    `,
  },
  {
    name: 'parameter new.target with body this and arguments captures',
    source: `
      function Run(value = (() => new.target === Run)()) {
        return [value, (() => this.base)(), (() => arguments.length)()];
      }
      Run.prototype.base = 9;
      console.log(JSON.stringify([new Run(), new Run(4)]));
    `,
  },
  {
    name: 'derived parameter new.target with body arguments capture',
    source: `
      class Base {}
      class Child extends Base {
        constructor(value = (() => new.target === Child)()) {
          super();
          this.result = [value, (() => arguments.length)()];
        }
      }
      console.log(JSON.stringify([new Child().result, new Child(4).result]));
    `,
  },
  {
    name: 'nested function in default retains its own captures',
    source: `
      const host = { base: 9 };
      function run(value = (() => {
        function nested(inner = (() => this.base + arguments.length)()) { return inner; }
        return [this.base, arguments.length, nested.call({ base: 2 })];
      })()) { return value; }
      console.log(JSON.stringify([run.call(host), run.call(host, 4)]));
    `,
  },
  {
    name: 'generator default throws at call time before body starts',
    source: `
      const events = [];
      function* run(value = (() => {
        events.push(this.base, arguments.length);
        throw new Error('parameter');
      })()) { events.push('body'); yield value; }
      try { run.call({ base: 7 }); } catch (error) { events.push(error.message); }
      console.log(JSON.stringify(events));
    `,
  },
  {
    name: 'ordinary function',
    source: `
      const host = { base: 3 };
      let calls = 0;
      function run(value = (() => { calls++; return this?.base + arguments.length; })()) { return value; }
      console.log(JSON.stringify([run.call(host), run.call(host, 4), calls]));
    `,
  },
  {
    name: 'async function',
    source: `
      const host = { base: 3 };
      let calls = 0;
      async function run(value = (() => { calls++; return this.base + arguments.length; })()) { return value; }
      Promise.all([run.call(host), run.call(host, 4)]).then(function (values) {
        console.log(JSON.stringify([values[0], values[1], calls]));
      });
    `,
  },
  {
    name: 'generator function',
    source: `
      const host = { base: 3 };
      let calls = 0;
      function* run(value = (() => { calls++; return this.base + arguments.length; })()) { yield value; }
      const first = run.call(host);
      console.log(JSON.stringify([calls, first.next().value, run.call(host, 4).next().value, calls]));
    `,
  },
  {
    name: 'async generator function',
    source: `
      const host = { base: 3 };
      let calls = 0;
      async function* run(value = (() => { calls++; return this.base + arguments.length; })()) { yield value; }
      const first = run.call(host);
      Promise.all([first.next(), run.call(host, 4).next()]).then(function (values) {
        console.log(JSON.stringify([calls, values[0].value, values[1].value, calls]));
      });
    `,
  },
  {
    name: 'computed parameter property restores a captured arrow name through graph imports',
    source: `
      globalThis.key = 'read';
      const host = {};
      function run(value = { [globalThis.key]: () => this }) {
        const fn = value[globalThis.key];
        return [fn.name, fn() === this];
      }
      console.log(JSON.stringify(run.call(host)));
    `,
  },
  {
    name: 'named-property stack does not call patched array prototype methods',
    source: `
      const originalPush = Array.prototype.push;
      const originalPop = Array.prototype.pop;
      let calls = 0;
      Array.prototype.push = function (value) { calls++; return originalPush.call(this, value); };
      Array.prototype.pop = function () { calls++; return originalPop.call(this); };
      globalThis.key = 'read';
      function run(value = { [globalThis.key]: () => this }) { return value[globalThis.key].name; }
      const name = run.call({});
      Array.prototype.push = originalPush;
      Array.prototype.pop = originalPop;
      console.log(name, calls);
    `,
  },
  {
    name: 'keep-names helper captures object intrinsics before source mutation',
    source: `
      const originalCreate = Object.create;
      const originalDefineProperty = Object.defineProperty;
      let calls = 0;
      Object.create = function () { calls++; return originalCreate.apply(this, arguments); };
      Object.defineProperty = function () { calls++; return originalDefineProperty.apply(this, arguments); };
      function run(value = { read: () => this }) { return value.read.name; }
      const name = run.call({});
      Object.create = originalCreate;
      Object.defineProperty = originalDefineProperty;
      console.log(name, calls);
    `,
  },
  {
    name: 'symbol description getter is captured with source Object and Symbol shadows',
    source: `
      const objectConstructor = globalThis.Object;
      const symbolConstructor = globalThis.Symbol;
      const descriptor = objectConstructor.getOwnPropertyDescriptor(symbolConstructor.prototype, 'description');
      let calls = 0;
      objectConstructor.defineProperty(symbolConstructor.prototype, 'description', {
        configurable: true,
        get: function () { calls++; return descriptor.get.call(this); },
      });
      const key = symbolConstructor('read');
      function run(value = { [key]: () => this }) { return value[key].name; }
      const name = run.call({});
      objectConstructor.defineProperty(symbolConstructor.prototype, 'description', descriptor);
      const Object = 1, Symbol = 2;
      console.log(name, calls, Object, Symbol);
    `,
  },
  {
    name: 'string computed-key helper does not read a preloaded global Symbol getter',
    expected: '[[true,"read"],0]\n',
    preload: `
      globalThis.symbolReads = 0;
      globalThis.savedSymbol = Object.getOwnPropertyDescriptor(globalThis, 'Symbol');
      Object.defineProperty(globalThis, 'Symbol', {
        configurable: true,
        get: function () { globalThis.symbolReads++; return globalThis.savedSymbol.value; },
      });
    `,
    source: `
      globalThis.key = 'read';
      function run(value = { [globalThis.key]: () => this }) {
        return [value[globalThis.key]() === this, value[globalThis.key].name];
      }
      const result = run.call({});
      const reads = globalThis.symbolReads;
      Object.defineProperty(globalThis, 'Symbol', globalThis.savedSymbol);
      console.log(JSON.stringify([result, reads]));
    `,
  },
  {
    name: 'string computed-key helper tolerates a throwing preloaded global Symbol getter',
    expected: '[[true,"read"],0]\n',
    preload: `
      globalThis.symbolReads = 0;
      globalThis.savedSymbol = Object.getOwnPropertyDescriptor(globalThis, 'Symbol');
      Object.defineProperty(globalThis, 'Symbol', {
        configurable: true,
        get: function () { globalThis.symbolReads++; throw new Error('unexpected Symbol read'); },
      });
    `,
    source: `
      globalThis.key = 'read';
      function run(value = { [globalThis.key]: () => this }) {
        return [value[globalThis.key]() === this, value[globalThis.key].name];
      }
      const result = run.call({});
      const reads = globalThis.symbolReads;
      Object.defineProperty(globalThis, 'Symbol', globalThis.savedSymbol);
      console.log(JSON.stringify([result, reads]));
    `,
  },
  {
    name: 'symbol computed-key helper preserves the name without reading a preloaded global Symbol getter',
    expected: '[[true,"[read]"],0]\n',
    preload: `
      globalThis.symbolReads = 0;
      globalThis.savedSymbol = Object.getOwnPropertyDescriptor(globalThis, 'Symbol');
      globalThis.symbolKey = globalThis.savedSymbol.value('read');
      Object.defineProperty(globalThis, 'Symbol', {
        configurable: true,
        get: function () { globalThis.symbolReads++; return globalThis.savedSymbol.value; },
      });
    `,
    source: `
      function run(value = { [globalThis.symbolKey]: () => this }) {
        return [value[globalThis.symbolKey]() === this, value[globalThis.symbolKey].name];
      }
      const result = run.call({});
      const reads = globalThis.symbolReads;
      Object.defineProperty(globalThis, 'Symbol', globalThis.savedSymbol);
      console.log(JSON.stringify([result, reads]));
    `,
  },
];

describe('parameter arrow this/arguments captures precede default checks (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const fixture of cases) {
    const bins = fixture.preload ? (['zig', 'js'] as const) : (['zig'] as const);
    for (const bin of bins) {
      for (const bundle of [false, true]) {
        for (const minify of [false, true]) {
          test(`${fixture.name}, ${bin}, ${bundle ? 'bundle' : 'single'}, ${minify ? 'minify' : 'plain'}`, async () => {
            const files: Record<string, string> = {
              'input.mjs': fixture.source,
              'package.json': '{"type":"module"}',
            };
            if (fixture.preload) files['preload.cjs'] = fixture.preload;
            const dir = await createFixture(files);
            cleanup = dir.cleanup;
            const input = join(dir.dir, 'input.mjs');
            const preloadArgs = fixture.preload ? ['--require', join(dir.dir, 'preload.cjs')] : [];
            const native = spawnSync('node', [...preloadArgs, input], { encoding: 'utf8' });
            expect(native.status, native.stderr).toBe(0);
            if (fixture.expected !== undefined) expect(native.stdout).toBe(fixture.expected);
            const output = join(dir.dir, bundle ? 'out.cjs' : 'out.mjs');
            const result = await runZntcInDir(
              dir.dir,
              [
                ...(bundle ? ['--bundle', '--platform=node', '--format=cjs'] : []),
                'input.mjs',
                '--target=es5',
                ...(minify ? ['--minify'] : []),
                '-o',
                output,
              ],
              { bin },
            );
            expect(result.exitCode, result.stderr).toBe(0);
            const actual = spawnSync('node', [...preloadArgs, output], { encoding: 'utf8' });
            expect(actual.status, actual.stderr).toBe(0);
            expect(actual.stdout).toBe(native.stdout);
          });
        }
      }
    }
  }
});
