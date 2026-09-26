import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntcInDir } from './helpers';

const cases = [
  {
    name: 'ordinary class method inside async function',
    source: `(async function () {
      class Host { constructor() { this.base = 3; }
        run(value = (() => this.base + arguments.length)()) { return value; } }
      console.log(new Host().run());
    })();`,
  },
  {
    name: 'async class method inside async function',
    source: `(async function () {
      class Host { constructor() { this.base = 3; }
        async run(value = (() => this.base + arguments.length)()) { return value; } }
      console.log(await new Host().run());
    })();`,
  },
  {
    name: 'generator class method inside async function',
    source: `(async function () {
      class Host { constructor() { this.base = 3; }
        *run(value = (() => this.base + arguments.length)()) { yield value; } }
      console.log(new Host().run().next().value);
    })();`,
  },
  {
    name: 'async generator class method inside async function',
    source: `(async function () {
      class Host { constructor() { this.base = 3; }
        async *run(value = (() => this.base + arguments.length)()) { yield value; } }
      console.log((await new Host().run().next()).value);
    })();`,
  },
  {
    name: 'base constructor',
    source: `class Host {
      constructor(value = (() => (this instanceof Host ? 3 : 0) + arguments.length)()) { this.value = value; }
    }
    console.log(JSON.stringify([new Host().value, new Host(4).value]));`,
  },
  {
    name: 'class setter parameter',
    source: `class Host {
      constructor() { this.base = 3; }
      set value(input = (() => this.base + arguments.length)()) { this.last = input; }
    }
    const host = new Host();
    Object.getOwnPropertyDescriptor(Host.prototype, 'value').set.call(host);
    console.log(host.last);`,
  },
  {
    name: 'class setter parameter inside async function',
    source: `(async function () {
      class Host {
        constructor() { this.base = 3; }
        set value(input = (() => this.base + arguments.length)()) { this.last = input; }
      }
      const host = new Host();
      Object.getOwnPropertyDescriptor(Host.prototype, 'value').set.call(host);
      console.log(host.last);
    })();`,
  },
  {
    name: 'class getter body arrow inside async function',
    source: `(async function () {
      class Host {
        constructor() { this.base = 3; }
        get value() { return (() => this.base + arguments.length)(); }
      }
      console.log(new Host().value);
    })();`,
  },
  {
    name: 'base constructor inside async function',
    source: `(async function () {
      class Host {
        constructor(value = (() => (this instanceof Host ? 3 : 0) + arguments.length)()) { this.value = value; }
      }
      console.log(new Host().value);
    })();`,
  },
  {
    name: 'derived constructor arguments before super and body this after super',
    source: `class Base { constructor() { this.base = 3; } }
    class Host extends Base {
      constructor(value = (() => arguments.length)()) {
        super();
        this.read = () => this.base;
        this.value = value;
      }
    }
    const host = new Host();
    console.log(JSON.stringify([host.value, host.read()]));`,
  },
  {
    name: 'derived constructor inside async function',
    source: `(async function () {
      class Base { constructor() { this.base = 3; } }
      class Host extends Base {
        constructor(value = (() => arguments.length)()) {
          super();
          this.read = () => this.base;
          this.value = value;
        }
      }
      const host = new Host();
      console.log(JSON.stringify([host.value, host.read()]));
    })();`,
  },
  {
    name: 'derived constructor this default throws before super',
    source: `class Base {}
    class Host extends Base {
      constructor(value = (() => this.base)()) { super(); this.value = value; }
    }
    try { new Host(); console.log('no-throw'); }
    catch (error) { console.log(error.name); }`,
  },
  {
    name: 'derived constructor body arrow called before super',
    source: `class Base {}
    class Host extends Base {
      constructor() {
        const read = () => this;
        try { read(); console.log('no-throw'); }
        catch (error) { console.log(error.name); }
        super();
      }
    }
    new Host();`,
  },
  {
    name: 'ordinary private method',
    source: `class Host {
      constructor() { this.base = 3; }
      #run(value = (() => this.base + arguments.length)()) { return value; }
      run() { return this.#run(); }
    }
    console.log(new Host().run());`,
  },
  {
    name: 'ordinary private method inside async function',
    source: `(async function () {
      class Host {
        constructor() { this.base = 3; }
        #run(value = (() => this.base + arguments.length)()) { return value; }
        run() { return this.#run(); }
      }
      console.log(new Host().run());
    })();`,
  },
] as const;

describe('class parameter arrow capture order (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const fixture of cases) {
    for (const target of ['es5', 'es2015', 'es2017', 'esnext', 'hermes'] as const) {
      for (const bundle of [false, true]) {
        for (const minify of [false, true]) {
          test(`${fixture.name}, ${target}, ${bundle ? 'bundle' : 'single'}, ${minify ? 'minify' : 'plain'}`, async () => {
            const dir = await createFixture({
              'input.mjs': fixture.source,
              'package.json': '{"type":"module"}',
            });
            cleanup = dir.cleanup;
            const input = join(dir.dir, 'input.mjs');
            const native = spawnSync('node', [input], { encoding: 'utf8' });
            expect(native.status, native.stderr).toBe(0);
            const output = join(dir.dir, bundle ? 'out.cjs' : 'out.mjs');
            const result = await runZntcInDir(dir.dir, [
              ...(bundle ? ['--bundle', '--platform=node', '--format=cjs'] : []),
              'input.mjs',
              target === 'hermes' ? '--platform=react-native' : `--target=${target}`,
              ...(minify ? ['--minify'] : []),
              '-o',
              output,
            ]);
            expect(result.exitCode, result.stderr).toBe(0);
            const actual = spawnSync('node', [output], { encoding: 'utf8' });
            expect(actual.status, actual.stderr).toBe(0);
            expect(actual.stdout).toBe(native.stdout);
          });
        }
      }
    }
  }
});
