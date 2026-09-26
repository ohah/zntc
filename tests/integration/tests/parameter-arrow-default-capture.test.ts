import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntcInDir } from './helpers';

const cases = [
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
] as const;

describe('parameter arrow this/arguments captures precede default checks (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const fixture of cases) {
    for (const bundle of [false, true]) {
      for (const minify of [false, true]) {
        test(`${fixture.name}, ${bundle ? 'bundle' : 'single'}, ${minify ? 'minify' : 'plain'}`, async () => {
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
            '--target=es5',
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
});
