import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createPnpmFarmFixture, runZts } from './helpers';

describe('pnpm/bun farm symlink — bundle integration', () => {
  test('farm symlink resolves to real package and inlines source', async () => {
    const fixture = await createPnpmFarmFixture({
      files: {
        'src/index.ts': `import { greet } from 'foo';\nconsole.log(greet('zts'));\n`,
        'package.json': JSON.stringify({ name: 'pnpm-app', version: '0.0.0', type: 'module' }),
      },
      packages: {
        'foo@1.0.0': {
          'package.json': JSON.stringify({ name: 'foo', version: '1.0.0', main: './index.js' }),
          'index.js': `export function greet(name) { return 'hello, ' + name + '!'; }\n`,
        },
      },
    });

    try {
      const outFile = join(fixture.dir, 'out.js');
      const result = await runZts(['--bundle', join(fixture.dir, 'src/index.ts'), '-o', outFile]);

      expect(result.exitCode).toBe(0);

      const bundle = readFileSync(outFile, 'utf-8');
      expect(bundle).toContain('hello, ');
      expect(bundle).toContain('zts');
    } finally {
      await fixture.cleanup();
    }
  });
});
