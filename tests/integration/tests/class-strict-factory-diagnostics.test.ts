import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { existsSync } from 'node:fs';
import { createFixture, runZntc } from './helpers';
const cases = [
  {
    name: 'eval class-self write',
    source:
      "class Box{static #f(){try{eval('Box=1');return 'bad';}catch(e){return e.name;}}static read(){return this.#f();}}console.log(Box.read());",
  },
  {
    name: 'opaque eval class-self write',
    source:
      "class Box{static #f(code){try{eval(code);return 'bad';}catch(e){return e.name;}}static read(){return this.#f('Box=1');}}console.log(Box.read());",
  },
  {
    name: 'eval erased private environment',
    source:
      "class Box{static #value=7;static #f(){return eval('this.#value');}static read(){return this.#f();}}console.log(Box.read());",
  },
  {
    name: 'eval lexical local TDZ',
    source:
      "class Box{static #f(){try{{return eval('local');let local=7;}}catch(e){return e.name;}}static read(){return this.#f();}}console.log(Box.read());",
  },
  {
    name: 'eval shadowed class-name TDZ',
    source:
      "class Box{static #f(){try{{return eval('Box');let Box=7;}}catch(e){return e.name;}}static read(){return this.#f();}}console.log(Box.read());",
  },
  {
    name: 'eval later default parameter TDZ',
    source:
      "class Box{static #f(local=eval('later'),later=7){return local;}static read(){try{return this.#f();}catch(e){return e.name;}}}console.log(Box.read());",
  },
  {
    name: 'eval unknown generated-capture spelling',
    source:
      "class Box{static #f(){try{return eval('__zntc_class_self_value')===Box;}catch(e){return e.name;}}static read(){return this.#f();}}console.log(Box.read());",
  },
  {
    name: 'outer-bound builtin escaped eval write',
    source:
      "function run(eval){class Box{static #f(){try{(eval)('Box=1');return 'bad';}catch(e){return e.name;}}static read(){return this.#f();}}console.log(Box.read());}run(globalThis.eval);",
  },
];
describe('ES5 private factory dynamic environment fails explicitly (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });
  for (const fixture of cases)
    for (const bundle of [false, true])
      for (const format of [[], ['--format=cjs']])
        for (const minify of [[], ['--minify-identifiers'], ['--minify']]) {
          test(`${fixture.name}: ${bundle ? 'bundle' : 'standalone'}, ${format.join(' ') || 'default'}, ${minify.join(' ') || 'plain'}`, async () => {
            const created = await createFixture({ 'input.cjs': fixture.source });
            cleanup = created.cleanup;
            const input = join(created.dir, 'input.cjs');
            const output = join(created.dir, 'output.cjs');
            const native = spawnSync('node', [input], { encoding: 'utf8' });
            expect(native.status, native.stderr).toBe(0);
            const args = [
              input,
              ...(bundle ? ['--bundle', '--platform=node'] : []),
              ...format,
              ...minify,
              '-o',
              output,
            ];
            const rejected = await runZntc([...args, '--target=es5']);
            expect(rejected.exitCode).not.toBe(0);
            expect(rejected.stderr).toContain('ZNTC1505');
            expect(existsSync(output)).toBe(false);
            const retained = await runZntc([...args, '--target=es2022']);
            expect(retained.exitCode, retained.stderr).toBe(0);
            const executed = spawnSync('node', [output], { encoding: 'utf8' });
            expect(executed.status, executed.stderr).toBe(0);
            expect(executed.stdout).toBe(native.stdout);
          });
        }
});

describe('native private factory retains readonly const aliases (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });
  for (const fixture of cases.slice(0, 2))
    for (const target of ['es2015', 'es2017'])
      for (const bundle of [false, true])
        for (const minify of [[], ['--minify-identifiers'], ['--minify']]) {
          test(`${fixture.name}: ${target} ${bundle ? 'bundle' : 'standalone'} ${minify.join(' ') || 'plain'}`, async () => {
            const created = await createFixture({ 'input.cjs': fixture.source });
            cleanup = created.cleanup;
            const input = join(created.dir, 'input.cjs'),
              output = join(created.dir, 'output.cjs');
            const native = spawnSync('node', [input], { encoding: 'utf8' });
            expect(native.status, native.stderr).toBe(0);
            const result = await runZntc([
              input,
              `--target=${target}`,
              '--format=cjs',
              ...(bundle ? ['--bundle', '--platform=node'] : []),
              ...minify,
              '-o',
              output,
            ]);
            expect(result.exitCode, result.stderr).toBe(0);
            const executed = spawnSync('node', [output], { encoding: 'utf8' });
            expect(executed.status, executed.stderr).toBe(0);
            expect(executed.stdout).toBe(native.stdout);
          });
        }
});
