import { afterEach, describe, expect, test } from 'bun:test';
import { join } from 'node:path';
import { createFixture, runNode, runZntc } from './helpers';

describe('#4819 transform semantic graph for native JavaScript mangling', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  async function expectNativeParity(source: string, expected: string) {
    const fixture = await createFixture({ 'input.js': source });
    cleanup = fixture.cleanup;
    const input = join(fixture.dir, 'input.js');
    const output = join(fixture.dir, 'output.js');
    const result = await runZntc([input, '-o', output, '--minify-identifiers']);
    expect(result.exitCode).toBe(0);
    expect(result.stderr).toBe('');
    const native = await runNode(input);
    const transformed = await runNode(output);
    expect(native.stdout).toBe(expected);
    expect(transformed.stdout).toBe(native.stdout);
  }

  test('copied declarations retain their binding and nested scope', async () => {
    await expectNativeParity(
      `
        const outside = 17;
        function calculate(argument) {
          const local = argument + outside;
          function capture(argument) { return local + argument; }
          return capture(5);
        }
        console.log(calculate(3));
      `,
      '25',
    );
  });

  test('unresolved globals and shadowed names keep their meaning', async () => {
    await expectNativeParity(
      `
        const values = new Map([['x', 7]]);
        function lookup(MapValue) {
          let values = MapValue + 2;
          return values;
        }
        console.log(values.get('x') + lookup(3));
      `,
      '12',
    );
  });
});
