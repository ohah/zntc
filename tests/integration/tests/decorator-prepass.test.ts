import { afterEach, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createFixture, runNode, ZNTC_BIN } from './helpers';

describe('decorator option graph pre-pass gate', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  async function bundle(source: string) {
    const fixture = await createFixture({ 'input.ts': source });
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
        '--experimental-decorators',
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

  test('module without decorators skips the graph pre-pass', async () => {
    const result = await bundle('const answer: number = 42; process.stdout.write(String(answer));');
    expect(result.stderr).not.toContain('zntc: symbol-identity-prepass-mode ');
    expect(result.stdout).toBe('42');
  });

  test('decorated module keeps the graph pre-pass and runtime result', async () => {
    const result = await bundle(
      'function mark(value: any) { return value; }\n@mark\nclass Example {}\nprocess.stdout.write("42");',
    );
    expect(result.stderr).toContain('zntc: symbol-identity-prepass-mode ');
    expect(result.stdout).toBe('42');
  });
});
