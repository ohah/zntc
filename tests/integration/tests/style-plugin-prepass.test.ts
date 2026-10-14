import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runNode, ZNTC_JS_CLI } from './helpers';

describe('style plugin graph pre-pass gate', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  test('configured style plugins skip modules without recognized imports', async () => {
    const fixture = await createFixture({
      'index.ts': 'const answer: number = 42; process.stdout.write(String(answer));',
      'zntc.config.json': JSON.stringify({
        compiler: {
          styledComponents: { namespace: 'audit' },
          emotion: true,
        },
      }),
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'output.cjs');
    const result = spawnSync(
      'bun',
      [
        ZNTC_JS_CLI,
        '--bundle',
        join(fixture.dir, 'index.ts'),
        '-o',
        output,
        '--platform=node',
        '--format=cjs',
      ],
      {
        cwd: fixture.dir,
        env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
        encoding: 'utf8',
      },
    );
    expect(result.status, result.stderr).toBe(0);
    expect(result.stderr).not.toContain('zntc: symbol-identity-prepass-mode ');

    const execution = await runNode(output);
    expect(execution.stderr).toBe('');
    expect(execution.stdout).toBe('42');
  });
});
