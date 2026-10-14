import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createFixture, runNode, ZNTC_BIN } from './helpers';

describe('drop debugger graph pre-pass gate', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  async function bundle(source: string) {
    const fixture = await createFixture({ 'input.js': source });
    cleanup = fixture.cleanup;
    const output = join(fixture.dir, 'output.cjs');
    const result = spawnSync(
      ZNTC_BIN,
      [
        '--bundle',
        join(fixture.dir, 'input.js'),
        '-o',
        output,
        '--platform=node',
        '--format=cjs',
        '--drop=debugger',
      ],
      {
        cwd: fixture.dir,
        env: { ...process.env, ZNTC_DEBUG_SYMBOL_COVERAGE: '1' },
        encoding: 'utf8',
      },
    );
    expect(result.status, result.stderr).toBe(0);
    const code = readFileSync(output, 'utf8');
    const execution = await runNode(output);
    expect(execution.stderr).toBe('');
    return { code, stderr: result.stderr, stdout: execution.stdout };
  }

  test('module without debugger skips the graph pre-pass', async () => {
    const result = await bundle('console.log(42);');
    expect(result.stderr).not.toContain('zntc: symbol-identity-prepass-mode ');
    expect(result.stdout).toBe('42');
  });

  test('debugger module keeps the graph pre-pass and removes the statement', async () => {
    const result = await bundle('debugger; console.log(42);');
    expect(result.stderr).toContain('zntc: symbol-identity-prepass-mode ');
    expect(result.code).not.toContain('debugger');
    expect(result.stdout).toBe('42');
  });
});
