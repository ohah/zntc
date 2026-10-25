import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, ZNTC_BIN } from './helpers';

const cli = process.env.ZNTC_COMPUTED_KEY_WRITE_CLI ?? ZNTC_BIN;
const cases = [
  {
    name: 'computed constructor stays ordinary method',
    source:
      "const outside=7;class Box{value=outside;['constructor'](){return 2}}const box=new Box();console.log(box.value,box.constructor());",
  },
  {
    name: 'computed ordinary method',
    source:
      "const key='read';class Box{value=7;[key](){return this.value}}console.log(new Box().read());",
  },
  {
    name: 'computed getter',
    source: "class Box{value=7;get ['read'](){return this.value}}console.log(new Box().read);",
  },
  {
    name: 'computed setter',
    source:
      "class Box{value=7;set ['write'](x){this.saved=x}}const box=new Box();box.write=2;console.log(box.value,box.saved);",
  },
  {
    name: 'computed static method',
    source:
      "class Box{value=7;static ['read'](){return 2}}console.log(new Box().value,Box.read());",
  },
  {
    name: 'class expression computed method',
    source: "const Box=class{value=7;['read'](){return this.value}};console.log(new Box().read());",
  },
  {
    name: 'computed symbol method',
    source:
      "const key=Symbol('read');class Box{value=7;[key](){return this.value}}console.log(new Box()[key]());",
  },
  {
    name: 'computed method source order',
    source:
      "const events=[];function key(x){events.push(x);return x}class Box{value=(events.push('field'),7);[key('read')](){return this.value}[key('other')](){return 2}}const box=new Box();console.log(box.read(),box.other(),JSON.stringify(events));",
  },
  {
    name: 'nested class keeps own key temps',
    source:
      "class Box{value=7;['read'](){class Inner{value=2;['read'](){return this.value}}return[this.value,new Inner().read()]}}console.log(JSON.stringify(new Box().read()));",
  },
  {
    name: 'loop class evaluations keep computed method identity',
    source:
      "const result=[];for(let index=0;index<3;index++){class Box{value=index;['read'](){return this.value}}result.push(new Box().read())}console.log(JSON.stringify(result));",
  },
  {
    name: 'computed constructor default remains ordinary method',
    source:
      "const outside=7;class Box{value=outside;['constructor'](value=2){return value}}const box=new Box();console.log(box.value,box.constructor());",
  },
  {
    name: 'computed static method destructuring default',
    source:
      "class Box{value=7;static ['read']({value}={value:2}){return value}}console.log(new Box().value,Box.read());",
  },
];

describe('class computed key writer identity', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });
  for (const fixture of cases)
    for (const target of ['es5', 'es2015', 'es2022', 'chrome80', 'chrome84'])
      for (const bundle of [false, true])
        for (const define of [false, true])
          for (const mode of [[], ['--minify-identifiers'], ['--minify']]) {
            test(`${fixture.name} ${target} ${bundle ? 'bundle' : 'standalone'} define=${define} ${mode.join(' ') || 'plain'}`, async () => {
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
                  `--target=${target}`,
                  '--format=cjs',
                  ...(bundle ? ['--bundle', '--platform=node'] : []),
                  `--use-define-for-class-fields=${define}`,
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
