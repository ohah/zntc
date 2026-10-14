import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runNode, ZNTC_JS_CLI } from './helpers';

describe('React Refresh graph pre-pass path gate', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  test('non-target CommonJS modules skip the graph pre-pass', async () => {
    const fixture = await createFixture({
      'input.cjs':
        'function App() { return null; } const answer = 42; process.stdout.write(String(answer));',
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'output.cjs');
    const result = spawnSync(
      'bun',
      [
        ZNTC_JS_CLI,
        '--bundle',
        join(fixture.dir, 'input.cjs'),
        '-o',
        output,
        '--platform=node',
        '--format=cjs',
        '--react-refresh=true',
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
