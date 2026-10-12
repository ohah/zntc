import { describe, test, expect } from 'bun:test';
import { join } from 'node:path';
import { createFixture, runNode, runZntc } from './helpers';

async function expectEvalLookupToReadGlobal(evalArgument: string) {
  const fixture = await createFixture({
    'main.js':
      '// @flow\n' +
      'globalThis._a = "global";\n' +
      'function classify(input) {\n' +
      `  return match (input) { _ => eval(${evalArgument}) };\n` +
      '}\n' +
      'console.log(classify(42));\n',
  });
  try {
    const output = join(fixture.dir, 'out.js');
    const transpile = await runZntc([
      join(fixture.dir, 'main.js'),
      '--flow',
      '--target=esnext',
      '-o',
      output,
    ]);
    expect(transpile.exitCode, transpile.stderr).toBe(0);

    const result = await runNode(output);
    expect(result.stdout).toBe('global');
    expect(result.stderr).toBe('');
  } finally {
    await fixture.cleanup();
  }
}

describe('Flow match staging temp and direct eval', () => {
  test('a direct string literal does not expose the staging parameter', async () => {
    await expectEvalLookupToReadGlobal('"_a"');
  });

  test('an escaped static template does not expose the staging parameter', async () => {
    await expectEvalLookupToReadGlobal('`\\x5fa`');
  });

  test('an interpolated static template does not expose the staging parameter', async () => {
    await expectEvalLookupToReadGlobal('`_${"a"}`');
  });

  test('an escaped interpolated template does not expose the staging parameter', async () => {
    await expectEvalLookupToReadGlobal('`\\x5f${"a"}`');
  });

  test('statically concatenated strings do not expose the staging parameter', async () => {
    await expectEvalLookupToReadGlobal('"_" + "a"');
  });
});
