import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runNode } from './helpers';

describe('React Native worklet graph pre-pass gate', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  test(
    'ordinary modules skip the worklet pre-pass and preserve runtime output',
    { timeout: 30_000 },
    async () => {
      const fixture = await createFixture({
        'input.js': 'const answer = 41 + 1; console.log(answer);',
      });
      cleanup = fixture.cleanup;
      const output = join(fixture.dir, 'output.cjs');
      const coreEntry = join(import.meta.dir, '../../../packages/core/index.ts');
      const buildOptions = JSON.stringify({
        entryPoints: [join(fixture.dir, 'input.js')],
        platform: 'node',
        format: 'cjs',
        target: 'esnext',
        workletTransform: true,
        outfile: output,
      });
      const runner = [
        `import { build } from ${JSON.stringify(coreEntry)};`,
        `const result = await build(${buildOptions});`,
        'if (result.errors.length) { console.error(JSON.stringify(result.errors)); process.exit(1); }',
      ].join('\n');
      const result = spawnSync('bun', ['-e', runner], {
        cwd: join(import.meta.dir, '../../..'),
        env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
        encoding: 'utf8',
        timeout: 20_000,
      });
      expect(result.status, result.error?.message ?? result.stderr).toBe(0);
      expect(result.stderr).not.toContain('zntc: symbol-identity-prepass-mode ');

      const execution = await runNode(output);
      expect(execution.stdout).toBe('42');
    },
  );
});
