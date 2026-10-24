import { describe, expect, test } from 'bun:test';
import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import ts from 'typescript';
import { createFixture, runNode, runZntc } from './helpers';

const decorator = 'static decorate(...args:any[]){events.push(String(args[1])+":"+args.length);}';
const cases = [
  [
    'method parameter',
    `class Box {${decorator} method(@Box.decorate value:number){return value;}} new Box().method(7);`,
  ],
  [
    'constructor parameter',
    `class Box {${decorator} constructor(@Box.decorate value:number){events.push(String(value));}} new Box(7);`,
  ],
  [
    'method decorator',
    `class Box {${decorator} @Box.decorate method(){return 7;}} new Box().method();`,
  ],
  [
    'computed access',
    `class Box {${decorator} method(@(Box["decorate"]) value:number){return value;}} new Box().method(7);`,
  ],
  [
    'arrow evaluation',
    `class Box {${decorator} method(@((()=>Box.decorate)()) value:number){return value;}} new Box().method(7);`,
  ],
  [
    'named function shadow',
    `class Box {${decorator} method(@((function Box(Box:any){return Box;})(Box.decorate)) value:number){return value;}} new Box().method(7);`,
  ],
  [
    'nested class',
    `class Box {${decorator} method(@((()=>{class Inner {static value=1;} return Inner.value&&Box.decorate;})()) value:number){return value;}} new Box().method(7);`,
  ],
  [
    'block owner',
    `{class Box {${decorator} method(@Box.decorate value:number){return value;}} new Box().method(7);}`,
  ],
  [
    'constructor default',
    `class Box {${decorator} constructor(@Box.decorate value:number=7){events.push(String(value));}} new Box();`,
  ],
  [
    'combined constructor and method',
    `class Box {${decorator} constructor(@Box.decorate value:number=7){} @Box.decorate method(@Box.decorate value:number){return value;}} new Box().method(7);`,
  ],
] as const;

for (const [name, body] of cases) {
  describe(`legacy decorator exact self transfer: ${name}`, () => {
    for (const target of ['es5', 'es2015', 'es2017', 'es2020', 'es2022', 'esnext']) {
      for (const bundle of [false, true]) {
        for (const minify of [false, true]) {
          test(`${target} ${bundle ? 'bundle' : 'standalone'} ${minify ? 'minify' : 'plain'}`, async () => {
            const source = `const events:string[]=[];${body} console.log(JSON.stringify(events));`;
            const fixture = await createFixture({ 'input.ts': source });
            try {
              const reference = join(fixture.dir, 'reference.cjs');
              await writeFile(
                reference,
                ts.transpileModule(source, {
                  compilerOptions: { experimentalDecorators: true, target: ts.ScriptTarget.ESNext },
                }).outputText,
              );
              const expected = await runNode(reference);
              const output = join(fixture.dir, 'actual.cjs');
              const result = await runZntc(
                [
                  join(fixture.dir, 'input.ts'),
                  `--target=${target}`,
                  '--experimental-decorators',
                  ...(bundle ? ['--bundle', '--format=cjs'] : []),
                  ...(minify ? ['--minify'] : []),
                  '-o',
                  output,
                ],
                { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
              );
              expect(result.exitCode, result.stderr).toBe(0);
              // Runtime oracle complements the before-finalization identity unit.
              // Full exact gates remain in symbol-coverage.test.ts; nested source
              // name scopes and reanalyzed bundler decorators have separate debts.
              expect((await runNode(output)).stdout).toBe(expected.stdout);
            } finally {
              await fixture.cleanup();
            }
          }, 60000);
        }
      }
    }
  });
}
