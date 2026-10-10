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
function dec(value: any, context: any): any { return value; }
@dec
class Example { @dec method() { return 4; } }
@dec
class Another { @dec method() { return 5; } }
console.log(_metadata, _metadata2, _classThis, _classThis2, new Example().method(), new Another().method());
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

    const runtime = spawnSync('node', [output], { encoding: 'utf8' });
    expect(runtime.status, runtime.stderr).toBe(0);
    expect(runtime.stdout).toBe('11 12 21 22 4 5\n');
  });
});
