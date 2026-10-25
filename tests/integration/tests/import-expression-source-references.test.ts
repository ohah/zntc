import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';
const cli = process.env.ZNTC_IMPORT_SOURCE_REFERENCE_CLI ?? ZNTC_BIN;
const cases = [
  {
    name: 'const dynamic specifier',
    source: "const longName='node:os';import(longName).then(m=>console.log(typeof m.platform));",
  },
  {
    name: 'shadowed function parameter dynamic specifier',
    source:
      "const longName='node:path';function load(longName){return import(longName)}load('node:os').then(m=>console.log(typeof m.platform));",
  },
  {
    name: 'source options attribute reference',
    source:
      "const longName='node:os';const attrs={};import(longName,{with:attrs}).then(m=>console.log(typeof m.platform));",
  },
  {
    name: 'source argument closure preserves outer reference',
    source:
      "const longName='node:os';import((()=>longName)()).then(m=>console.log(typeof m.platform));",
  },
  {
    name: 'options closure preserves outer reference',
    source:
      "const attrs={};import('node:os',{with:(()=>attrs)()}).then(m=>console.log(typeof m.platform));",
  },
  {
    name: 'argument call side effects and source callee',
    source:
      "const events=[];function getPath(){events.push('path');return'node:os'}import(getPath()).then(m=>console.log(typeof m.platform,JSON.stringify(events)));",
  },
  {
    name: 'options call side effects and source callee',
    source:
      "const events=[];const attrs={};function getOptions(){events.push('options');return{with:attrs}}import('node:os',getOptions()).then(m=>console.log(typeof m.platform,JSON.stringify(events)));",
  },
  {
    name: 'attribute shorthand keeps static key and variable value',
    source:
      "const type='unsupported-source-test';import('node:os',{with:{type}}).then(()=>console.log('unexpected'),error=>console.log(error.code));",
  },
  {
    name: 'escaped identifier specifier maps to canonical source binding',
    source:
      "const long\\u004eame='node:os';import(longName).then(m=>console.log(typeof m.platform));",
  },
  {
    name: 'class field source binding excludes constructor parameter',
    source:
      "const longName='node:os';class Box{promise=import(longName);constructor(longName){}}new Box('node:path').promise.then(m=>console.log(typeof m.platform));",
  },
  {
    name: 'options parameter excludes same named outer binding',
    source:
      "const attrs={type:'unsupported-source-test'};function load(attrs){return import('node:os',{with:attrs})}load({}).then(m=>console.log(typeof m.platform));",
  },
  {
    name: 'options getter side effects and captured source reference',
    source:
      "const events=[];const attrs={};const options={get with(){events.push('with');return attrs}};import('node:os',options).then(m=>console.log(typeof m.platform,JSON.stringify(events)));",
  },
];
describe('initial import expression source references', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });
  for (const fixture of cases)
    for (const bundle of [false, true])
      for (const mode of [[], ['--minify-identifiers'], ['--minify']]) {
        test(`${fixture.name} ${bundle ? 'bundle' : 'standalone'} ${mode.join(' ') || 'plain'}`, async () => {
          const created = await createFixture({ 'input.mjs': fixture.source });
          cleanup = created.cleanup;
          const input = join(created.dir, 'input.mjs'),
            output = join(created.dir, 'output.mjs');
          const native = spawnSync('node', [input], { encoding: 'utf8' });
          expect(native.status, native.stderr).toBe(0);
          const built = spawnSync(
            cli,
            [
              input,
              '--target=esnext',
              '--format=esm',
              ...(bundle ? ['--bundle', '--platform=node'] : []),
              ...mode,
              '-o',
              output,
            ],
            { encoding: 'utf8', env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
          );
          expect(built.status, built.stderr).toBe(0);
          expect(built.stderr).not.toContain('clean=0');
          const actual = spawnSync('node', [output], { encoding: 'utf8' });
          expect(actual.status, actual.stderr).toBe(native.status);
          expect(actual.stdout).toBe(native.stdout);
        });
      }
});
