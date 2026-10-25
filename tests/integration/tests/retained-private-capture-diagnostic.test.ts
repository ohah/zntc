import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { build, buildSync, init } from '../../../packages/core/index.ts';
import { createFixture, ZNTC_BIN } from './helpers';
const cli = process.env.ZNTC_RETAINED_PRIVATE_CLI ?? ZNTC_BIN;
if (process.env.ZNTC_RETAINED_PRIVATE_NAPI) init(process.env.ZNTC_RETAINED_PRIVATE_NAPI);
const cases = [
  {
    name: 'instance field',
    source:
      "function Parent(){return()=>{with(new Proxy({},{has(){return true},get(t,n){return n===Symbol.unscopables?undefined:42}})){return class{\n#value=7;[this.key](){return this.#value}\n}}}}const Box=Parent.call({key:'read'})();console.log(new Box().read());",
    marker: '#value',
    error: 'private',
  },
  {
    name: 'instance method',
    source:
      "function Parent(){return()=>{with(new Proxy({},{has(){return true},get(t,n){return n===Symbol.unscopables?undefined:42}})){return class{\n#read(){return 7}[this.key](){return this.#read()}\n}}}}const Box=Parent.call({key:'read'})();console.log(new Box().read());",
    marker: '#read',
    error: 'private',
  },
  {
    name: 'private getter',
    source:
      "function Parent(){return()=>{with(new Proxy({},{has(){return true},get(t,n){return n===Symbol.unscopables?undefined:42}})){return class{\nget #read(){return 7}[this.key](){return this.#read}\n}}}}const Box=Parent.call({key:'read'})();console.log(new Box().read());",
    marker: '#read',
    error: 'private',
  },
  {
    name: 'private setter',
    source:
      "function Parent(){return()=>{with(new Proxy({},{has(){return true},get(t,n){return n===Symbol.unscopables?undefined:42}})){return class{\nset #write(value){this.value=value}[this.key](){this.#write=7;return this.value}\n}}}}const Box=Parent.call({key:'read'})();console.log(new Box().read());",
    marker: '#write',
    error: 'private',
  },
  {
    name: 'static field',
    source:
      "function Parent(){return()=>{with(new Proxy({},{has(){return true},get(t,n){return n===Symbol.unscopables?undefined:42}})){return class{\nstatic #value=7;static [this.key](){return this.#value}\n}}}}const Box=Parent.call({key:'read'})();console.log(Box.read());",
    marker: '#value',
    error: 'private',
  },
  {
    name: 'static method',
    source:
      "function Parent(){return()=>{with(new Proxy({},{has(){return true},get(t,n){return n===Symbol.unscopables?undefined:42}})){return class{\nstatic #read(){return 7}static [this.key](){return this.#read()}\n}}}}const Box=Parent.call({key:'read'})();console.log(Box.read());",
    marker: '#read',
    error: 'private',
  },
  {
    name: 'private brand',
    source:
      "function Parent(){return()=>{with(new Proxy({},{has(){return true},get(t,n){return n===Symbol.unscopables?undefined:42}})){return class{\n#value=7;[this.key](){return #value in this?7:0}\n}}}}const Box=Parent.call({key:'read'})();console.log(new Box().read());",
    marker: '#value',
    error: 'private',
  },
  {
    name: 'named class',
    source:
      "function Parent(){return()=>{with(new Proxy({},{has(){return true},get(t,n){return n===Symbol.unscopables?undefined:42}})){return class Named{\n#value=7;[this.key](){return this.#value}\n}}}}const Box=Parent.call({key:'read'})();console.log(new Box().read());",
    marker: '#value',
    error: 'private',
  },
  {
    name: 'outer with arrow creation',
    source:
      "function Parent(){with(new Proxy({},{has(){return true},get(t,n){return n===Symbol.unscopables?undefined:42}})){return()=>class{\n#value=7;[this.key](){return this.#value}\n}}}const Box=Parent.call({key:'read'})();console.log(new Box().read());",
    marker: '#value',
    error: 'private',
  },
  {
    name: 'opaque eval retention',
    source:
      "function Parent(code){return()=>{eval(code);return class{\n#value=7;[this.key](){return this.#value}\n}}}const Box=Parent.call({key:'read'},'1')();console.log(new Box().read());",
    marker: '#value',
    error: 'private',
  },
  {
    name: 'UTF8 private source coordinates',
    source:
      "const label='한글';function Parent(){return()=>{with(new Proxy({},{has(){return true},get(t,n){return n===Symbol.unscopables?undefined:42}})){return class{\n/*한*/ #값=7;[this.key](){return this.#값}\n}}}}const Box=Parent.call({key:'read'})();console.log(new Box().read());",
    marker: '#값',
    error: 'private',
  },
  {
    name: 'retained home object includes private sibling',
    source:
      'const object={Box:class{#value=7;read(){return this.#value}},__proto__:{value:7},read(){return()=>{with(new Proxy({},{has(){return true},get(t,n){return n===Symbol.unscopables?undefined:42}})){return super.value}}}};console.log(object.read()());',
    marker: '#value',
    error: 'object',
  },
  {
    name: 'private-looking string is not syntax',
    source:
      "function Parent(){return()=>{with(new Proxy({},{has(){return true},get(t,n){return n===Symbol.unscopables?undefined:42}})){return [this.value,'#value=7']}}}console.log(JSON.stringify(Parent.call({value:7})()));",
    marker: null,
    error: 'none',
  },
  {
    name: 'private sibling outside retained root',
    source:
      'class Other{#value=7;read(){return this.#value}}function Parent(){return()=>{with(new Proxy({},{has(){return true},get(t,n){return n===Symbol.unscopables?undefined:42}})){return this.value}}}console.log(new Other().read(),Parent.call({value:7})());',
    marker: null,
    error: 'none',
  },
];
const contexts = [
  {
    name: 'rn080',
    flags: ['--platform=react-native', '--rn-version=0.80'],
    options: { rnVersion: '0.80' },
  },
  {
    name: 'rn084',
    flags: ['--platform=react-native', '--rn-version=0.84'],
    options: { rnVersion: '0.84' },
  },
  { name: 'es5', flags: ['--target=es5', '--platform=node'], options: { target: 'es5' as const } },
  {
    name: 'es2022',
    flags: ['--target=es2022', '--platform=node'],
    options: { target: 'es2022' as const },
  },
];
function rejects(kind: string, target: string, bundle: boolean) {
  return (
    (kind === 'private' && (target === 'es5' || (target.startsWith('rn') && bundle))) ||
    (kind === 'object' && target === 'es5')
  );
}
describe('retained private capture diagnostic boundary', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });
  for (const fixture of cases)
    for (const context of contexts)
      for (const bundle of [false, true])
        for (const mode of [[], ['--minify-identifiers'], ['--minify']]) {
          test(`${fixture.name} ${context.name} bundle=${bundle} ${mode.join(' ') || 'plain'}`, async () => {
            const created = await createFixture({ 'input.cjs': fixture.source });
            cleanup = created.cleanup;
            const input = join(created.dir, 'input.cjs'),
              output = join(created.dir, 'out.cjs');
            const native = spawnSync('node', [input], { encoding: 'utf8' });
            expect(native.status, native.stderr).toBe(0);
            const built = spawnSync(
              cli,
              [
                input,
                ...context.flags,
                ...(bundle ? ['--bundle'] : []),
                '--format=cjs',
                ...mode,
                '-o',
                output,
              ],
              { encoding: 'utf8' },
            );
            if (rejects(fixture.error, context.name, bundle)) {
              expect(built.status, built.stderr).toBe(1);
              expect(built.stderr).toContain('ZNTC1506');
              expect(existsSync(output)).toBe(false);
            } else {
              expect(built.status, built.stderr).toBe(0);
              const actual = spawnSync('node', [output], { encoding: 'utf8' });
              expect(actual.status, actual.stderr).toBe(0);
              expect(actual.stdout).toBe(native.stdout);
            }
          });
        }
  for (const fixture of cases)
    for (const context of contexts)
      for (const api of ['buildSync', 'build'] as const) {
        test(`${fixture.name} ${context.name} ${api} source diagnostic`, async () => {
          const created = await createFixture({ 'input.cjs': fixture.source });
          cleanup = created.cleanup;
          const input = join(created.dir, 'input.cjs');
          const options = {
            entryPoints: [input],
            format: 'cjs' as const,
            write: false,
            ...context.options,
          };
          const result = api === 'buildSync' ? buildSync(options) : await build(options);
          if (rejects(fixture.error, context.name, true)) {
            const diagnostic = result.errors.find(
              (error) => error.code === 'arrow_private_dynamic_scope',
            );
            expect(diagnostic).toBeDefined();
            expect(diagnostic?.location?.file.endsWith('input.cjs')).toBe(true);
            const index = fixture.source.indexOf(fixture.marker!),
              prefix = fixture.source.slice(0, index);
            expect(diagnostic?.location?.offset).toBe(Buffer.byteLength(prefix));
            expect(diagnostic?.location?.length).toBe(Buffer.byteLength(fixture.marker!));
            expect(diagnostic?.location?.line).toBe(prefix.split('\n').length);
            expect(diagnostic?.location?.column).toBe(
              Buffer.byteLength(prefix.slice(prefix.lastIndexOf('\n') + 1)),
            );
          } else {
            expect(result.errors).toHaveLength(0);
            for (const warning of result.warnings.filter(
              (w) => w.code === 'arrow_dynamic_scope' || w.code === 'arrow_dynamic_eval',
            ))
              for (const key of ['offset', 'length', 'line', 'column'])
                expect(Object.hasOwn(warning.location ?? {}, key)).toBe(false);
          }
        });
      }
  test('default CLI file path renders typed error and UTF8 source position', async () => {
    const fixture = cases.find((f) => f.name === 'UTF8 private source coordinates')!;
    const created = await createFixture({ 'input.cjs': fixture.source });
    cleanup = created.cleanup;
    const input = join(created.dir, 'input.cjs'),
      output = join(created.dir, 'out.cjs');
    const built = spawnSync(cli, [input, '--target=es5', '-o', output], { encoding: 'utf8' });
    expect(built.status).toBe(1);
    expect(built.stderr).toContain('ZNTC1506');
    expect(built.stderr).toContain('input.cjs:2:9');
    expect(existsSync(output)).toBe(false);
  });
});
