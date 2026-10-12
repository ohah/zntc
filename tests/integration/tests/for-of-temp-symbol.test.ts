import { describe, test, expect } from 'bun:test';
import { join } from 'node:path';
import { createFixture, runNode, runZntc } from './helpers';

describe('standalone for-of temp SymbolIds (#4819)', () => {
  test('downlevel temps preserve source and unresolved temp-like names', async () => {
    const fixture = await createFixture({
      'main.mjs':
        'globalThis._b = "global";\n' +
        'globalThis._c = "global-c";\n' +
        'globalThis._d = "global-d";\n' +
        'const _a = "source";\n' +
        'const values = [1, 2, 3];\n' +
        'let total = 0;\n' +
        'for (const value of values) total += value;\n' +
        'console.log(_a, _b, _c, _d, total);\n',
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
      expect(result.stdout).toBe('source global global-c global-d 6');
      expect(result.stderr).toBe('');
    } finally {
      await fixture.cleanup();
    }
  });
});
