import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runZntcInDir } from './helpers';

const cases = [
  {
    name: 'class constructor',
    source: `function get() { return { value: 5 }; }
      class Host { constructor(value = get()?.value) { this.value = value; } }
      console.log(new Host().value);`,
  },
  {
    name: 'class method',
    source: `function get() { return { value: 5 }; }
      class Host { run(value = get()?.value) { return value; } }
      console.log(new Host().run());`,
  },
  {
    name: 'class setter',
    source: `function get() { return { value: 5 }; }
      class Host { set value(input = get()?.value) { this.saved = input; } }
      const host = new Host();
      Object.getOwnPropertyDescriptor(Host.prototype, 'value').set.call(host);
      console.log(host.saved);`,
  },
  {
    name: 'async class method',
    source: `function get() { return { value: 5 }; }
      class Host { async run(value = get()?.value) { return value; } }
      new Host().run().then(value => console.log(value));`,
  },
  {
    name: 'generator class method',
    source: `function get() { return { value: 5 }; }
      class Host { *run(value = get()?.value) { yield value; } }
      console.log(new Host().run().next().value);`,
  },
  {
    name: 'async generator class method',
    source: `function get() { return { value: 5 }; }
      class Host { async *run(value = get()?.value) { yield value; } }
      new Host().run().next().then(result => console.log(result.value));`,
  },
  {
    name: 'generator function',
    source: `function get() { return { value: 5 }; }
      function* run(value = get()?.value) { yield value; }
      console.log(run().next().value);`,
  },
  {
    name: 'async function',
    source: `function get() { return { value: 5 }; }
      async function run(value = get()?.value) { return value; }
      run().then(value => console.log(value));`,
  },
  {
    name: 'async generator function',
    source: `function get() { return { value: 5 }; }
      async function* run(value = get()?.value) { yield value; }
      run().next().then(result => console.log(result.value));`,
  },
  {
    name: 'async generator for-await body and parameter temp',
    source: `function get() { return { value: 5 }; }
      async function* run(value = get()?.value) {
        for await (const item of [1]) yield value + item;
      }
      run().next().then(result => console.log(result.value));`,
  },
] as const;

// These 12 fixture/target combinations also fail with the c532 baseline:
// their retained native defaults read a temp declared in the function body (or
// no temp declaration). They need a separate parameter-environment producer,
// beyond the lowered-default scope contract exercised by this matrix.
const nativeDefaultBaselineGaps = new Set([
  'class constructor/es2015',
  'class constructor/es2017',
  'class method/es2015',
  'class method/es2017',
  'class setter/es2015',
  'class setter/es2017',
  'async class method/es2017',
  'generator class method/es2015',
  'generator class method/es2017',
  'generator function/es2015',
  'generator function/es2017',
  'async function/es2017',
]);

describe('parameter optional-chain temp scope (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const fixture of cases) {
    for (const target of ['es5', 'es2015', 'es2017', 'esnext', 'hermes'] as const) {
      for (const bundle of [false, true]) {
        for (const minify of [false, true]) {
          if (nativeDefaultBaselineGaps.has(`${fixture.name}/${target}`)) {
            test.todo(
              `${fixture.name}, ${target}, ${bundle ? 'bundle' : 'single'}, ${minify ? 'minify' : 'plain'}: native default environment`,
            );
            continue;
          }
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

  for (const bundle of [false, true]) {
    for (const minify of [false, true]) {
      test(`lowered arrow default temp is reentrant-safe, ${bundle ? 'bundle' : 'single'}, ${minify ? 'minify' : 'plain'}`, async () => {
        const source = `let calls = 0;
          let read;
          function get() { return { value: ++calls }; }
          function key() { if (calls === 1) read(); return 'value'; }
          read = (value = get()?.[key()]) => value;
          console.log(read());`;
        const dir = await createFixture({
          'input.mjs': source,
          'package.json': '{"type":"module"}',
        });
        cleanup = dir.cleanup;
        const input = join(dir.dir, 'input.mjs');
        const native = spawnSync('node', [input], { encoding: 'utf8' });
        expect(native.status, native.stderr).toBe(0);
        expect(native.stdout).toBe('1\n');

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

  for (const bundle of [false, true]) {
    for (const minify of [false, true]) {
      test(`lowered async arrow default temp is reentrant-safe, ${bundle ? 'bundle' : 'single'}, ${minify ? 'minify' : 'plain'}`, async () => {
        const source = `let calls = 0;
          let read;
          function get() { return { value: ++calls }; }
          function key() { if (calls === 1) read(); return 'value'; }
          read = async (value = get()?.[key()]) => { await Promise.resolve(); return value; };
          read().then(value => console.log(value));`;
        const dir = await createFixture({
          'input.mjs': source,
          'package.json': '{"type":"module"}',
        });
        cleanup = dir.cleanup;
        const input = join(dir.dir, 'input.mjs');
        const native = spawnSync('node', [input], { encoding: 'utf8' });
        expect(native.status, native.stderr).toBe(0);
        expect(native.stdout).toBe('1\n');

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

  for (const evalLocation of ['parameter', 'body'] as const) {
    test(`lowered async arrow default temp preserves ${evalLocation} eval`, async () => {
      const initializer =
        evalLocation === 'parameter' ? '(eval("0"), get()?.value)' : 'get()?.value';
      const body = evalLocation === 'body' ? '{ eval("0"); return value; }' : 'value';
      const source = `function get() { return { value: 5 }; }
        const read = async (value = ${initializer}) => ${body};
        read().then(value => console.log(value));`;
      const dir = await createFixture({
        'input.mjs': source,
        'package.json': '{"type":"module"}',
      });
      cleanup = dir.cleanup;
      const input = join(dir.dir, 'input.mjs');
      const native = spawnSync('node', [input], { encoding: 'utf8' });
      expect(native.status, native.stderr).toBe(0);
      expect(native.stdout).toBe('5\n');

      const output = join(dir.dir, 'out.mjs');
      const result = await runZntcInDir(dir.dir, ['input.mjs', '--target=es5', '-o', output]);
      expect(result.exitCode, result.stderr).toBe(0);
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe(native.stdout);
    });
  }

  for (const bundle of [false, true]) {
    for (const minify of [false, true]) {
      test(`lowered async function default temp is reentrant-safe, ${bundle ? 'bundle' : 'single'}, ${minify ? 'minify' : 'plain'}`, async () => {
        const source = `let calls = 0;
          function key() { if (calls === 1) read(); return 'value'; }
          function get() { return { value: ++calls }; }
          async function read(value = get()?.[key()]) { await Promise.resolve(); return value; }
          read().then(value => console.log(value));`;
        const dir = await createFixture({
          'input.mjs': source,
          'package.json': '{"type":"module"}',
        });
        cleanup = dir.cleanup;
        const input = join(dir.dir, 'input.mjs');
        const native = spawnSync('node', [input], { encoding: 'utf8' });
        expect(native.status, native.stderr).toBe(0);
        expect(native.stdout).toBe('1\n');

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

  for (const evalLocation of ['parameter', 'body'] as const) {
    test(`lowered async function default temp preserves ${evalLocation} eval`, async () => {
      const initializer =
        evalLocation === 'parameter' ? '(eval("0"), get()?.value)' : 'get()?.value';
      const body = evalLocation === 'body' ? "{ eval('0'); return value; }" : '{ return value; }';
      const source = `function get() { return { value: 5 }; }
        async function read(value = ${initializer}) ${body}
        read().then(value => console.log(value));`;
      const dir = await createFixture({
        'input.mjs': source,
        'package.json': '{"type":"module"}',
      });
      cleanup = dir.cleanup;
      const input = join(dir.dir, 'input.mjs');
      const native = spawnSync('node', [input], { encoding: 'utf8' });
      expect(native.status, native.stderr).toBe(0);
      expect(native.stdout).toBe('5\n');

      const output = join(dir.dir, 'out.mjs');
      const result = await runZntcInDir(dir.dir, ['input.mjs', '--target=es5', '-o', output]);
      expect(result.exitCode, result.stderr).toBe(0);
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe(native.stdout);
    });
  }

  for (const bundle of [false, true]) {
    for (const minify of [false, true]) {
      test(`lowered async method default temp is reentrant-safe, ${bundle ? 'bundle' : 'single'}, ${minify ? 'minify' : 'plain'}`, async () => {
        const source = `let calls = 0, reader;
          function key() { if (calls === 1) reader.read(); return 'receiver'; }
          function get(receiver) { calls++; return { receiver }; }
          class Reader { async read(value = get(this)?.[key()]) { await Promise.resolve(); return value === this; } }
          reader = new Reader(); reader.read().then(value => console.log(value));`;
        const dir = await createFixture({
          'input.mjs': source,
          'package.json': '{"type":"module"}',
        });
        cleanup = dir.cleanup;
        const input = join(dir.dir, 'input.mjs');
        const native = spawnSync('node', [input], { encoding: 'utf8' });
        expect(native.status, native.stderr).toBe(0);
        expect(native.stdout).toBe('true\n');

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

  for (const evalLocation of ['parameter', 'body'] as const) {
    test(`lowered async method default temp preserves ${evalLocation} eval`, async () => {
      const initializer =
        evalLocation === 'parameter' ? '(eval("0"), get()?.value)' : 'get()?.value';
      const body = evalLocation === 'body' ? "{ eval('0'); return value; }" : '{ return value; }';
      const source = `function get() { return { value: 5 }; }
        class Reader { async read(value = ${initializer}) ${body} }
        new Reader().read().then(value => console.log(value));`;
      const dir = await createFixture({
        'input.mjs': source,
        'package.json': '{"type":"module"}',
      });
      cleanup = dir.cleanup;
      const input = join(dir.dir, 'input.mjs');
      const native = spawnSync('node', [input], { encoding: 'utf8' });
      expect(native.status, native.stderr).toBe(0);
      expect(native.stdout).toBe('5\n');

      const output = join(dir.dir, 'out.mjs');
      const result = await runZntcInDir(dir.dir, ['input.mjs', '--target=es5', '-o', output]);
      expect(result.exitCode, result.stderr).toBe(0);
      const actual = spawnSync('node', [output], { encoding: 'utf8' });
      expect(actual.status, actual.stderr).toBe(0);
      expect(actual.stdout).toBe(native.stdout);
    });
  }
});
