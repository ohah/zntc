import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createFixture, runZntcInDir } from './helpers';

describe('Stage 3 decorator runtime helper symbols (#4819)', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  for (const minify of [false, true]) {
    test(`standalone ${minify ? 'minified ' : ''}Stage 3 decorator helpers use collision-free SymbolId names`, async () => {
      const sourceNames = minify
        ? ['$eD', '$rI', '$sF', '$pK']
        : ['__esDecorate', '__runInitializers', '__setFunctionName', '__propKey'];
      const fixture = await createFixture({
        'input.ts': `
var ${sourceNames[0]} = 7, ${sourceNames[1]} = 8, ${sourceNames[2]} = 9, ${sourceNames[3]} = 10;
function dec(value: any, context: any): any { return value; }
@dec
class Example {
  @dec method() { return 3; }
  @dec value = 4;
}
console.log(${sourceNames.join(', ')}, new Example().value);
`,
      });
      cleanup = fixture.cleanup;
      const output = join(fixture.dir, 'out.js');
      const result = await runZntcInDir(fixture.dir, [
        'input.ts',
        '--target=es5',
        ...(minify ? ['--minify-whitespace'] : []),
        '-o',
        output,
      ]);
      expect(result.exitCode, result.stderr).toBe(0);

      const code = readFileSync(output, 'utf8');
      const helperPatterns = minify
        ? [
            /var (\$eD[a-zA-Z0-9_$]*)=function\(/,
            /var (\$rI[a-zA-Z0-9_$]*)=function\(/,
            /var (\$sF[a-zA-Z0-9_$]*)=function\(/,
            /var (\$pK[a-zA-Z0-9_$]*)=function\(/,
          ]
        : [
            /var (__esDecorate\d*) = function\(/,
            /var (__runInitializers\d*) = function\(/,
            /var (__setFunctionName\d*) = function\(/,
            /var (__propKey\d*) = function\(/,
          ];
      const helperNames = helperPatterns.map((pattern) => code.match(pattern)?.[1]);
      expect(helperNames.every(Boolean)).toBe(true);
      expect(new Set(helperNames).size).toBe(4);
      for (const [index, helperName] of helperNames.entries()) {
        expect(helperName).not.toBe(sourceNames[index]);
      }
      for (const helperName of helperNames.slice(0, 2)) {
        expect(code).toContain(`${helperName}(`);
      }

      const runtime = spawnSync('node', [output], { encoding: 'utf8' });
      expect(runtime.status, runtime.stderr).toBe(0);
      expect(runtime.stdout).toBe('7 8 9 10 4\n');
    });
  }

  test('standalone Stage 3 metadata binding gets its output name from its exact SymbolId', async () => {
    const fixture = await createFixture({
      'input.ts': `
var _metadata = 11, _metadata2 = 12;
var _classThis = 21, _classThis2 = 22;
var _classDecorators = 31, _classDecorators2 = 32;
var _classDescriptor = 41, _classDescriptor2 = 42;
var _classExtraInitializers = 51, _classExtraInitializers2 = 52;
var _method_decorators = 61, _method_decorators2 = 62;
var _value_decorators = 71, _value_decorators2 = 72;
var _value_initializers = 81, _value_initializers2 = 82;
var _value_extraInitializers = 91, _value_extraInitializers2 = 92;
var _instanceExtraInitializers = 101, _instanceExtraInitializers2 = 102;
var _staticMethod_decorators = 111, _staticMethod_decorators2 = 112;
var _staticExtraInitializers = 121, _staticExtraInitializers2 = 122;
function dec(value: any, context: any): any { return value; }
@dec
class Example {
  @dec method() { return 4; }
  @dec value = 6;
  @dec static staticMethod() { return 8; }
}
@dec
class Another {
  @dec method() { return 5; }
  @dec value = 7;
  @dec static staticMethod() { return 9; }
}
console.log(_metadata, _metadata2, _classThis, _classThis2, _classDecorators, _classDecorators2, _classDescriptor, _classDescriptor2, _classExtraInitializers, _classExtraInitializers2, _method_decorators, _method_decorators2, _value_decorators, _value_decorators2, _value_initializers, _value_initializers2, _value_extraInitializers, _value_extraInitializers2, _instanceExtraInitializers, _instanceExtraInitializers2, _staticMethod_decorators, _staticMethod_decorators2, _staticExtraInitializers, _staticExtraInitializers2, new Example().method(), new Example().value, Example.staticMethod(), new Another().method(), new Another().value, Another.staticMethod());
`,
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'out.js');
    const result = await runZntcInDir(fixture.dir, ['input.ts', '--target=es5', '-o', output]);
    expect(result.exitCode, result.stderr).toBe(0);

    const code = readFileSync(output, 'utf8');
    expect(code).toContain('var _metadata = 11');
    expect(code).toContain('_metadata2 = 12');
    expect(code).toMatch(/\b_metadata3\s*=/);
    expect(code).toMatch(/\b_metadata4\s*=/);
    expect(code).toMatch(/\b_classThis3\b/);
    expect(code).toMatch(/\b_classThis4\b/);
    expect(code).toMatch(/\b_classDecorators3\b/);
    expect(code).toMatch(/\b_classDecorators4\b/);
    expect(code).toMatch(/\b_classDescriptor3\b/);
    expect(code).toMatch(/\b_classDescriptor4\b/);
    expect(code).toMatch(/\b_classExtraInitializers3\b/);
    expect(code).toMatch(/\b_classExtraInitializers4\b/);
    expect(code).toMatch(/\b_method_decorators3\b/);
    expect(code).toMatch(/\b_method_decorators4\b/);
    expect(code).toMatch(/\b_value_decorators3\b/);
    expect(code).toMatch(/\b_value_decorators4\b/);
    expect(code).toMatch(/\b_value_initializers3\b/);
    expect(code).toMatch(/\b_value_initializers4\b/);
    expect(code).toMatch(/\b_value_extraInitializers3\b/);
    expect(code).toMatch(/\b_value_extraInitializers4\b/);
    expect(code).toMatch(/\b_instanceExtraInitializers3\b/);
    expect(code).toMatch(/\b_instanceExtraInitializers4\b/);
    expect(code).toMatch(/\b_staticMethod_decorators3\b/);
    expect(code).toMatch(/\b_staticMethod_decorators4\b/);
    expect(code).toMatch(/\b_staticExtraInitializers3\b/);
    expect(code).toMatch(/\b_staticExtraInitializers4\b/);

    const runtime = spawnSync('node', [output], { encoding: 'utf8' });
    expect(runtime.status, runtime.stderr).toBe(0);
    expect(runtime.stdout).toBe(
      '11 12 21 22 31 32 41 42 51 52 61 62 71 72 81 82 91 92 101 102 111 112 121 122 4 6 8 5 7 9\n',
    );
  });

  test('standalone private Stage 3 descriptor bindings get distinct exact SymbolId names', async () => {
    const fixture = await createFixture({
      'input.ts': `
var _private_secret_descriptor = 131, _private_secret_descriptor2 = 132;
const accesses: any[] = [];
function dec(value: any, context: any): any {
  if (context.private) accesses.push(context.access);
  return value;
}
@dec class Example { @dec #secret() { return 10; } }
@dec class Another { @dec #secret() { return 11; } }
const example = new Example(), another = new Another();
console.log(
  _private_secret_descriptor,
  _private_secret_descriptor2,
  accesses[0].has(example),
  accesses[0].get(example).call(example),
  accesses[1].has(another),
  accesses[1].get(another).call(another),
);
`,
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'out.js');
    const result = await runZntcInDir(fixture.dir, ['input.ts', '--target=es5', '-o', output]);
    expect(result.exitCode, result.stderr).toBe(0);

    const code = readFileSync(output, 'utf8');
    expect(code).toContain('var _private_secret_descriptor = 131');
    expect(code).toContain('_private_secret_descriptor2 = 132');
    expect(code).toMatch(/\b_private_secret_descriptor3\s*=/);
    expect(code).toMatch(/\b_private_secret_descriptor4\s*=/);
    expect(code).not.toContain('obj.#secret');

    const runtime = spawnSync('node', [output], { encoding: 'utf8' });
    expect(runtime.status, runtime.stderr).toBe(0);
    expect(runtime.stdout).toBe('131 132 true 10 true 11\n');
  });

  test('direct eval outside the Stage 3 wrapper cannot observe its member locals', async () => {
    const fixture = await createFixture({
      'input.ts': `
function dec(value: any, context: any): any { return value; }
function run() {
  var seen: string;
  eval("seen = typeof _method_decorators");
  @dec class Example { @dec method() { return 1; } }
  return seen + " " + new Example().method();
}
console.log(run());
`,
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'out.js');
    const result = await runZntcInDir(fixture.dir, ['input.ts', '--target=es5', '-o', output]);
    expect(result.exitCode, result.stderr).toBe(0);

    const runtime = spawnSync('node', [output], { encoding: 'utf8' });
    expect(runtime.status, runtime.stderr).toBe(0);
    expect(runtime.stdout).toBe('undefined 1\n');
  });
});
