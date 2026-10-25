import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

const cli = process.env.ZNTC_INNER_WITH_CAPTURE_CLI ?? ZNTC_BIN;
const warning =
  'a lexical-capturing arrow or its containing class/object literal inside a with statement is emitted unchanged';
const cases = [
  {
    name: 'native parameter new target',
    source:
      'function Parent(get=()=>{with(new Proxy({},{has(){return true},get(t,n){return n===Symbol.unscopables?undefined:42}})){return new.target}}){return get}console.log(new Parent()()===Parent);',
    policy: true,
  },
  {
    name: 'body arrow this',
    source:
      'function Parent(){return()=>{with(new Proxy({},{has(){return true},get(t,n){return n===Symbol.unscopables?undefined:42}})){return this}}}const object={};console.log(Parent.call(object)()===object);',
    policy: true,
  },
  {
    name: 'body arrow arguments selective proxy',
    source:
      "function Parent(value){return()=>{with(new Proxy({},{has(t,n){return n[0]==='_';},get(t,n){return n===Symbol.unscopables?undefined:42}})){return arguments[0]}}}console.log(Parent(7)());",
    policy: true,
  },
  {
    name: 'escaped arguments selective proxy',
    source:
      "function Parent(value){return()=>{with(new Proxy({},{has(t,n){return n[0]==='_';},get(t,n){return n===Symbol.unscopables?undefined:42}})){return argum\\u0065nts[0]}}}console.log(Parent(7)());",
    policy: true,
  },
  {
    name: 'nested block new target',
    source:
      'function Parent(){return()=>{with(new Proxy({},{has(){return true},get(t,n){return n===Symbol.unscopables?undefined:42}})){{return new.target}}}}console.log(new Parent()()===Parent);',
    policy: true,
  },
  {
    name: 'nested arrow new target',
    source:
      'function Parent(){return()=>{with(new Proxy({},{has(){return true},get(t,n){return n===Symbol.unscopables?undefined:42}})){return()=>new.target}}}console.log(new Parent()()()===Parent);',
    policy: true,
  },
  {
    name: 'class heritage outer this',
    source:
      'function Parent(){return()=>{with(new Proxy({},{has(){return true},get(t,n){return n===Symbol.unscopables?undefined:42}})){return class extends this.Base{}}}}const Base=class{};const C=Parent.call({Base})();console.log(Object.getPrototypeOf(C)===Base);',
    policy: true,
  },
  {
    name: 'class computed key outer this',
    source:
      "function Parent(){return()=>{with(new Proxy({},{has(){return true},get(t,n){return n===Symbol.unscopables?undefined:42}})){return class{[this.key](){return 7}}}}}const C=Parent.call({key:'read'})();console.log(new C().read());",
    policy: true,
  },
  {
    name: 'object computed key outer this',
    source:
      "function Parent(){return()=>{with(new Proxy({},{has(){return true},get(t,n){return n===Symbol.unscopables?undefined:42}})){return{[this.key](){return 7}}}}}console.log(Parent.call({key:'read'})().read());",
    policy: true,
  },
  {
    name: 'source arguments intercepted by proxy',
    source:
      "function Parent(value){return()=>{with(new Proxy({},{has(t,n){return n==='arguments'||n[0]==='_';},get(t,n){return n===Symbol.unscopables?undefined:n==='arguments'?[99]:42}})){return arguments[0]}}}console.log(Parent(7)());",
    policy: true,
  },
  {
    name: 'native parameter this',
    source:
      'function Parent(get=()=>{with(new Proxy({},{has(){return true},get(t,n){return n===Symbol.unscopables?undefined:42}})){return this}}){return get}const object={};console.log(Parent.call(object)()===object);',
    policy: true,
  },
  {
    name: 'capture outside with',
    source:
      'function Parent(){return()=>{with(new Proxy({},{has(){return true},get(t,n){return n===Symbol.unscopables?undefined:42}})){void 0}return new.target}}console.log(new Parent()()===Parent);',
    policy: false,
  },
  {
    name: 'with object expression outside body',
    source:
      'function Parent(){return()=>{with({value:this.value}){return value}}}console.log(Parent.call({value:7})());',
    policy: false,
  },
  {
    name: 'ordinary function owns this',
    source:
      'function Parent(){return()=>function(){with(new Proxy({},{has(){return true},get(t,n){return n===Symbol.unscopables?undefined:42}})){return this}}}const read=Parent()();const object={};console.log(read.call(object)===object);',
    policy: false,
  },
  {
    name: 'object method owns this',
    source:
      'function Parent(){return()=>{with(new Proxy({},{has(){return true},get(t,n){return n===Symbol.unscopables?undefined:42}})){return{read(){return this}}}}}const object=Parent()();console.log(object.read()===object);',
    policy: false,
  },
  {
    name: 'arrow own arguments parameter',
    source:
      "const read=arguments=>{with(new Proxy({},{has(t,n){return n[0]==='_';},get(t,n){return n===Symbol.unscopables?undefined:42}})){return arguments[0]}};console.log(read([7]));",
    policy: false,
  },
  {
    name: 'object method preserves lexical super home',
    source:
      'const object={__proto__:{value:7},read(){return()=>{with(new Proxy({},{has(){return true},get(t,n){return n===Symbol.unscopables?undefined:42}})){return super.value}}}};console.log(object.read()());',
    policy: true,
  },
  {
    name: 'static arguments property is not capture',
    source:
      'const object={arguments:7};const read=()=>{with({}){return object.arguments}};console.log(read());',
    policy: false,
  },
  {
    name: 'arguments object key is not capture',
    source: 'const read=()=>{with({}){return {arguments:7}}};console.log(read().arguments);',
    policy: false,
  },
  {
    name: 'arguments method key is not capture',
    source:
      'const read=()=>{with({}){return {arguments(){return 7}}}};console.log(read().arguments());',
    policy: false,
  },
  {
    name: 'nested arrow captures outer arguments parameter',
    source: 'const read=(arguments)=>()=>{with({}){return arguments[0]}};console.log(read([7])());',
    policy: true,
  },
  {
    name: 'nested arrow owns arguments parameter',
    source: 'const read=()=>arguments=>{with({}){return arguments[0]}};console.log(read()([7]));',
    policy: false,
  },
  {
    name: 'ordinary arguments method outside with',
    source: 'const read=()=>({arguments(){return 7}});console.log(read().arguments());',
    policy: false,
  },
  {
    name: 'async arguments method outside with',
    source:
      'const read=()=>({async arguments(){return 7}});read().arguments().then(value=>console.log(value));',
    policy: false,
  },
  {
    name: 'generator arguments method outside with',
    source:
      'const read=()=>({*arguments(){yield 7}});console.log(read().arguments().next().value);',
    policy: false,
  },
  {
    name: 'arguments getter outside with',
    source: 'const read=()=>({get arguments(){return 7}});console.log(read().arguments);',
    policy: false,
  },
  {
    name: 'arguments setter outside with',
    source:
      'const read=()=>({set arguments(value){this.value=value}});const object=read();object.arguments=7;console.log(object.value);',
    policy: false,
  },
  {
    name: 'native class arguments method outside with',
    source:
      'const read=()=>class{arguments(){return 7}};const Box=read();console.log(new Box().arguments());',
    policy: false,
  },
  {
    name: 'computed arguments expression still evaluates',
    source:
      "function Parent(name){return()=>({[arguments[0]](){return 7}})}console.log(Parent('read')().read());",
    policy: false,
  },
  {
    name: 'computed key lowering still visits expression',
    source:
      "let calls=0;const read=()=>({[(calls++,null??'read')](){return 7}});console.log(calls,read().read(),calls);",
    policy: false,
  },
];
const targets = [
  {
    name: 'rn080',
    flags: ['--platform=react-native', '--rn-version=0.80'],
    lower: true,
    bundleOnly: true,
  },
  {
    name: 'rn084',
    flags: ['--platform=react-native', '--rn-version=0.84'],
    lower: true,
    bundleOnly: true,
  },
  { name: 'es5', flags: ['--target=es5', '--platform=node'], lower: true, bundleOnly: false },
  {
    name: 'es2022',
    flags: ['--target=es2022', '--platform=node'],
    lower: false,
    bundleOnly: false,
  },
];

describe('inner with arrow capture retention policy', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });
  for (const fixture of cases)
    for (const target of targets)
      for (const bundle of [false, true])
        for (const mode of [[], ['--minify-identifiers'], ['--minify']]) {
          test(`${fixture.name} ${target.name} bundle=${bundle} ${mode.join(' ') || 'plain'}`, async () => {
            const created = await createFixture({ 'input.cjs': fixture.source });
            cleanup = created.cleanup;
            const input = join(created.dir, 'input.cjs'),
              output = join(created.dir, 'output.cjs');
            const native = spawnSync('node', [input], { encoding: 'utf8' });
            expect(native.status, native.stderr).toBe(0);
            const built = spawnSync(
              cli,
              [
                input,
                ...target.flags,
                ...(bundle ? ['--bundle'] : []),
                '--format=cjs',
                ...mode,
                '-o',
                output,
              ],
              { encoding: 'utf8' },
            );
            expect(built.status, built.stderr).toBe(0);
            // --rn-version explicitly warns that it is ignored without --bundle.
            const effectiveLower = target.lower && (!target.bundleOnly || bundle);
            expect(built.stderr.includes(warning)).toBe(fixture.policy && effectiveLower);
            const code = readFileSync(output, 'utf8');
            if (
              fixture.name === 'computed key lowering still visits expression' &&
              target.name === 'es5'
            )
              expect(code).not.toContain('??');
            if (fixture.policy && effectiveLower) expect(code).toContain('=>');
            else if (effectiveLower) expect(code).not.toContain('=>');
            const actual = spawnSync('node', [output], { encoding: 'utf8' });
            expect(actual.status, actual.stderr).toBe(native.status);
            expect(actual.stdout).toBe(native.stdout);
          });
        }
});
