import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import ts from 'typescript';
import { createFixture, runNode, runZntc } from './helpers';
import { build, buildSync, close, init, transpile } from '../../../packages/core/index';

const cases = [
  {
    name: 'class',
    source:
      'const events:string[]=[]; function dec(...args:any[]){events.push(args.length===1?"class":String(args[1]));return args.length===1?args[0]:undefined;} @dec export default class {method(){return 7;}} console.log(JSON.stringify(events));',
  },
  {
    name: 'member',
    source:
      'const events:string[]=[]; function dec(...args:any[]){events.push(args.length===1?"class":String(args[1]));return args.length===1?args[0]:undefined;} export default class {@dec method(){return 7;}} console.log(JSON.stringify(events));',
  },
  {
    name: 'combined',
    source:
      'const events:string[]=[]; function dec(...args:any[]){events.push(args.length===1?"class":String(args[1]));return args.length===1?args[0]:undefined;} @dec export default class {@dec method(){return 7;}} console.log(JSON.stringify(events));',
  },
  {
    name: 'ctor',
    source:
      'const events:string[]=[]; function dec(...args:any[]){events.push(args.length===1?"class":String(args[1]));return args.length===1?args[0]:undefined;} export default class {constructor(@dec value:number=7){} method(){return 7;}} console.log(JSON.stringify(events));',
  },
  {
    name: 'static',
    source:
      'const events:string[]=[]; function dec(...args:any[]){events.push(args.length===1?"class":String(args[1]));return args.length===1?args[0]:undefined;} export default class {@dec static read(){return 1;} method(){return 7;}} console.log(JSON.stringify(events));',
  },
  {
    name: 'getter',
    source:
      'const events:string[]=[]; function dec(...args:any[]){events.push(args.length===1?"class":String(args[1]));return args.length===1?args[0]:undefined;} export default class {@dec get value(){return 1;} method(){return 7;}} console.log(JSON.stringify(events));',
  },
  {
    name: 'field',
    source:
      'const events:string[]=[]; function dec(...args:any[]){events.push(args.length===1?"class":String(args[1]));return args.length===1?args[0]:undefined;} export default class {@dec value=1; method(){return 7;}} console.log(JSON.stringify(events));',
  },
  {
    name: 'computed',
    source:
      'const events:string[]=[]; function dec(...args:any[]){events.push(args.length===1?"class":String(args[1]));return args.length===1?args[0]:undefined;} export default class {@dec ["meth"+"od"](){return 7;}} console.log(JSON.stringify(events));',
  },
  {
    name: 'two-class',
    source:
      'const events:string[]=[]; function dec(...args:any[]){events.push(args.length===1?"class":String(args[1]));return args.length===1?args[0]:undefined;} @dec @dec export default class {method(){return 7;}} console.log(JSON.stringify(events));',
  },
  {
    name: 'decoy',
    source:
      'const events:string[]=[]; function dec(...args:any[]){events.push(args.length===1?"class":String(args[1]));return args.length===1?args[0]:undefined;} const _Class=99; @dec export default class {method(){return 7;} other(){return _Class;}} console.log(JSON.stringify(events));',
  },
  {
    name: 'existing generated static name',
    source:
      'const events:string[]=[]; function dec(...args:any[]){events.push(args.length===1?"class":String(args[1]));return args.length===1?args[0]:undefined;} @dec export default class {static value=1;method(){return 7;}} console.log(JSON.stringify(events));',
  },
  {
    name: 'existing generated private name',
    source:
      'const events:string[]=[]; function dec(...args:any[]){events.push(args.length===1?"class":String(args[1]));return args.length===1?args[0]:undefined;} @dec export default class {#read(){return 7;} method(){return this.#read();}} console.log(JSON.stringify(events));',
  },
] as const;

async function execute(file: string, launcher: string) {
  await writeFile(
    launcher,
    `const m=require(${JSON.stringify(file)}); const C=typeof m==='function'?m:m.default; console.log('value',new C().method());`,
  );
  return (await runNode(launcher)).stdout;
}

for (const { name, source } of cases) {
  describe(`anonymous legacy default export: ${name}`, () => {
    for (const target of ['es5', 'es2015', 'es2017', 'es2020', 'es2022', 'esnext']) {
      for (const bundle of [false, true]) {
        for (const minify of ['', '--minify-identifiers', '--minify']) {
          test(`${target} ${bundle ? 'bundle' : 'standalone'} ${minify || 'plain'}`, async () => {
            const fixture = await createFixture({ 'input.ts': source });
            try {
              const oracle = join(fixture.dir, 'oracle.cjs');
              await writeFile(
                oracle,
                ts.transpileModule(source, {
                  compilerOptions: {
                    experimentalDecorators: true,
                    target: ts.ScriptTarget.ESNext,
                    module: ts.ModuleKind.CommonJS,
                  },
                }).outputText,
              );
              const expected = await execute(oracle, join(fixture.dir, 'oracle-launcher.cjs'));
              const output = join(fixture.dir, 'actual.cjs');
              const result = await runZntc(
                [
                  join(fixture.dir, 'input.ts'),
                  `--target=${target}`,
                  '--experimental-decorators',
                  '--format=cjs',
                  ...(bundle ? ['--bundle'] : []),
                  ...(minify ? [minify] : []),
                  '-o',
                  output,
                ],
                { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
              );
              expect(result.exitCode, result.stderr).toBe(0);
              if (!bundle) {
                const report = result.stderr
                  .split('\n')
                  .find((line) => line.startsWith('zntc: symbol-identity '));
                expect(report, result.stderr).toMatch(/clean=1(?:\s|$)/);
              }
              expect(await execute(output, join(fixture.dir, 'actual-launcher.cjs'))).toBe(
                expected,
              );
            } finally {
              await fixture.cleanup();
            }
          }, 60000);
        }
      }
    }
  });
}

describe('anonymous legacy default class inferred name', () => {
  const source =
    'const events:string[]=[]; function dec(value:any){events.push("decorator:"+value.name);return value;} @dec export default class {get name(){return "instance";}static observed=this.name;static {events.push("static:"+this.name+":"+this.observed);}method(){return this.constructor.name+":"+(this.constructor as any).observed;}} console.log(JSON.stringify(events));';

  for (const target of ['es5', 'esnext']) {
    for (const bundle of [false, true]) {
      for (const minify of ['', '--minify']) {
        test(`${target} ${bundle ? 'bundle' : 'standalone'} ${minify || 'plain'}`, async () => {
          const fixture = await createFixture({ 'input.ts': source });
          try {
            const output = join(fixture.dir, 'actual.cjs');
            const result = await runZntc(
              [
                join(fixture.dir, 'input.ts'),
                `--target=${target}`,
                '--experimental-decorators',
                '--format=cjs',
                ...(bundle ? ['--bundle'] : []),
                ...(minify ? [minify] : []),
                '-o',
                output,
              ],
              { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
            );
            expect(result.exitCode, result.stderr).toBe(0);
            if (!bundle) {
              const report = result.stderr
                .split('\n')
                .find((line) => line.startsWith('zntc: symbol-identity '));
              expect(report, result.stderr).toMatch(/clean=1(?:\s|$)/);
            }
            expect(await execute(output, join(fixture.dir, 'actual-launcher.cjs'))).toBe(
              '["static:default:default","decorator:default"]\nvalue default:default',
            );
          } finally {
            await fixture.cleanup();
          }
        }, 60000);
      }
    }
  }

  for (const target of ['es5', 'es2022'] as const) {
    for (const surface of ['transpile', 'buildSync', 'build'] as const) {
      test(`${target} ${surface}`, async () => {
        const fixture = await createFixture({ 'input.ts': source });
        try {
          const output = join(fixture.dir, 'actual.cjs');
          let code: string;
          if (surface === 'transpile') {
            const result = transpile(source, {
              filename: join(fixture.dir, 'input.ts'),
              target,
              format: 'cjs',
              experimentalDecorators: true,
              minifyIdentifiers: true,
            });
            expect(result.errors ?? []).toHaveLength(0);
            code = result.code;
          } else {
            const options = {
              entryPoints: [join(fixture.dir, 'input.ts')],
              outfile: output,
              write: false,
              target,
              format: 'cjs' as const,
              experimentalDecorators: true,
              minifyIdentifiers: true,
            };
            const result = surface === 'buildSync' ? buildSync(options) : await build(options);
            expect(result.errors ?? []).toHaveLength(0);
            expect(result.outputFiles).toHaveLength(1);
            code = result.outputFiles[0]!.text;
          }
          await writeFile(output, code);
          expect(await execute(output, join(fixture.dir, 'actual-launcher.cjs'))).toBe(
            '["static:default:default","decorator:default"]\nvalue default:default',
          );
        } finally {
          await fixture.cleanup();
        }
      }, 60000);
    }
  }
});

describe('anonymous legacy default class explicit static name', () => {
  const source =
    'const events:string[]=[]; function dec(value:any){events.push(value.name);return value;} @dec export default class {static get name(){return "custom";}method(){return this.constructor.name;}} console.log(JSON.stringify(events));';

  for (const target of ['es2022', 'esnext']) {
    for (const bundle of [false, true]) {
      for (const minify of ['', '--minify']) {
        test(`${target} ${bundle ? 'bundle' : 'standalone'} ${minify || 'plain'}`, async () => {
          const fixture = await createFixture({ 'input.ts': source });
          try {
            const output = join(fixture.dir, 'actual.cjs');
            const result = await runZntc(
              [
                join(fixture.dir, 'input.ts'),
                `--target=${target}`,
                '--experimental-decorators',
                '--format=cjs',
                ...(bundle ? ['--bundle'] : []),
                ...(minify ? [minify] : []),
                '-o',
                output,
              ],
              { env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' } },
            );
            expect(result.exitCode, result.stderr).toBe(0);
            if (!bundle) {
              const report = result.stderr
                .split('\n')
                .find((line) => line.startsWith('zntc: symbol-identity '));
              expect(report, result.stderr).toMatch(/clean=1(?:\s|$)/);
            }
            expect(await execute(output, join(fixture.dir, 'actual-launcher.cjs'))).toBe(
              '["custom"]\nvalue custom',
            );
          } finally {
            await fixture.cleanup();
          }
        }, 60000);
      }
    }
  }
});

describe('anonymous legacy default export public native APIs', () => {
  beforeAll(() => init());
  afterAll(() => close());
  for (const { name, source } of cases) {
    for (const target of ['es5', 'es2022'] as const) {
      for (const surface of ['transpile', 'buildSync', 'build'] as const) {
        test(`${name} ${target} ${surface}`, async () => {
          const fixture = await createFixture({ 'input.ts': source });
          try {
            const oracle = join(fixture.dir, 'oracle.cjs');
            await writeFile(
              oracle,
              ts.transpileModule(source, {
                compilerOptions: {
                  experimentalDecorators: true,
                  target: ts.ScriptTarget.ESNext,
                  module: ts.ModuleKind.CommonJS,
                },
              }).outputText,
            );
            const expected = await execute(oracle, join(fixture.dir, 'oracle-launcher.cjs'));
            const output = join(fixture.dir, 'actual.cjs');
            let code: string;
            if (surface === 'transpile') {
              const result = transpile(source, {
                filename: join(fixture.dir, 'input.ts'),
                target,
                format: 'cjs',
                experimentalDecorators: true,
                minifyIdentifiers: true,
              });
              expect(result.errors ?? []).toHaveLength(0);
              code = result.code;
            } else {
              const options = {
                entryPoints: [join(fixture.dir, 'input.ts')],
                outfile: output,
                write: false,
                target,
                format: 'cjs' as const,
                experimentalDecorators: true,
                minifyIdentifiers: true,
              };
              const result = surface === 'buildSync' ? buildSync(options) : await build(options);
              expect(result.errors ?? []).toHaveLength(0);
              expect(result.outputFiles).toHaveLength(1);
              code = result.outputFiles[0]!.text;
            }
            await writeFile(output, code);
            expect(await execute(output, join(fixture.dir, 'actual-launcher.cjs'))).toBe(expected);
          } finally {
            await fixture.cleanup();
          }
        }, 60000);
      }
    }
  }
});
