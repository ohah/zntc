import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { createFixture, runNode, ZNTC_BIN } from './helpers';

describe('useDefineForClassFields graph pre-pass gate', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  async function bundle(source: string) {
    const fixture = await createFixture({
      'input.ts': source,
    });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'output.cjs');
    const result = spawnSync(
      ZNTC_BIN,
      [
        '--bundle',
        join(fixture.dir, 'input.ts'),
        '-o',
        output,
        '--platform=node',
        '--format=cjs',
        '--target=esnext',
        '--use-define-for-class-fields=false',
      ],
      {
        cwd: fixture.dir,
        env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
        encoding: 'utf8',
      },
    );
    expect(result.status, result.stderr).toBe(0);
    const execution = await runNode(output);
    expect(execution.stderr).toBe('');
    return { stderr: result.stderr, stdout: execution.stdout };
  }

  test('classless module skips the graph pre-pass and runs unchanged', async () => {
    const result = await bundle('const baseValue = 41; console.log(baseValue + 1);');
    expect(result.stderr).not.toContain('zntc: symbol-identity-prepass-mode ');
    expect(result.stdout).toBe('42');
  });

  test('class field module keeps the graph pre-pass and runs unchanged', async () => {
    const result = await bundle('class Box { value = 41; } console.log(new Box().value + 1);');
    expect(result.stderr).toContain('zntc: symbol-identity-prepass-mode ');
    expect(result.stdout).toBe('42');
  });
});
