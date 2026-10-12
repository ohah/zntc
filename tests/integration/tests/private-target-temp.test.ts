import { describe, test, expect } from 'bun:test';
import { join } from 'node:path';
import { createFixture, runNode, runZntc } from './helpers';

describe('private target temp SymbolId (#4819)', () => {
  test('standalone downlevel for-in preserves declared and unresolved temp-like names', async () => {
    const fixture = await createFixture({
      'main.mjs':
        'globalThis._b = "global";\n' +
        'class Counter {\n' +
        '  #value;\n' +
        '  run() {\n' +
        '    const _a = "source";\n' +
        '    console.log("before", _a, _b);\n' +
        '    { for (this.#value in { first: 1, second: 2 }) {} }\n' +
        '    console.log("after", _a, _b, this.#value);\n' +
        '  }\n' +
        '}\n' +
        'new Counter().run();\n',
    });
    try {
      const output = join(fixture.dir, 'out.cjs');
      const transpile = await runZntc([
        join(fixture.dir, 'main.mjs'),
        '--target=es5',
        '-o',
        output,
      ]);
      expect(transpile.exitCode, transpile.stderr).toBe(0);

      const result = await runNode(output);
      expect(result.stdout).toBe('before source global\nafter source global second');
      expect(result.stderr).toBe('');
    } finally {
      await fixture.cleanup();
    }
  });
});
