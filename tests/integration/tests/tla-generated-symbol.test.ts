import { describe, test, expect } from 'bun:test';
import { join } from 'node:path';
import { createFixture, runNode, runZntc } from './helpers';

const TARGETS = [
  { name: 'ES2015', target: 'es2015' },
  { name: 'ES5', target: 'es5' },
];

describe('top-level-await result temp symbol (#4819)', () => {
  for (const variant of TARGETS) {
    test(`declared and global temp-like names survive the generated result temp — ${variant.name}`, async () => {
      const fixture = await createFixture({
        'main.mjs':
          'const _a = "user";\n' +
          'globalThis._b = "global";\n' +
          'console.log("before", _b);\n' +
          'await Promise.resolve();\n' +
          'console.log("after", _a, _b);\n',
      });
      try {
        const output = join(fixture.dir, 'out.cjs');
        const bundle = await runZntc([
          '--bundle',
          join(fixture.dir, 'main.mjs'),
          `--target=${variant.target}`,
          '--platform=node',
          '--format=cjs',
          '-o',
          output,
        ]);
        expect(bundle.exitCode, bundle.stderr).toBe(0);

        const result = await runNode(output);
        expect(result.stdout).toBe('before global\nafter user global');
        expect(result.stderr).toBe('');
      } finally {
        await fixture.cleanup();
      }
    });
  }

  test('unwrapped ESM entry waits for the exact lowered TLA promise', async () => {
    const fixture = await createFixture({
      'main.mjs':
        'const early = (async () => Promise.resolve("decoy"))();\n' +
        'export let value = 0;\n' +
        'await new Promise((resolve) => setTimeout(resolve, 20));\n' +
        'value = 42;\n',
      'verify.mjs': 'import { value } from "./bundle.mjs"; console.log(value);\n',
    });
    try {
      const output = join(fixture.dir, 'bundle.mjs');
      const bundle = await runZntc([
        '--bundle',
        join(fixture.dir, 'main.mjs'),
        '--target=es5',
        '--platform=node',
        '--format=esm',
        '-o',
        output,
      ]);
      expect(bundle.exitCode, bundle.stderr).toBe(0);

      const result = await runNode(join(fixture.dir, 'verify.mjs'));
      expect(result.stdout).toBe('42');
      expect(result.stderr).toBe('');
    } finally {
      await fixture.cleanup();
    }
  });
});
