import { describe, expect, runCli, test } from '../helpers';
import { useTranspileFixture } from './fixture';

describe('CLI: transpile', () => {
  const fixture = useTranspileFixture();

  test('--tokenize prints scanner tokens', () => {
    const { stdout, stderr, exitCode } = runCli([fixture.path('input.ts'), '--tokenize']);
    expect(exitCode).toBe(0);
    expect(stderr).not.toContain('unknown option');
    expect(stdout).toContain('const');
    expect(stdout).toContain('<identifier>');
    expect(stdout).toContain('<eof>');
    expect(stdout).not.toContain('const x = 1');
  });

  test('--tokenize-format=json prints machine-readable tokens', () => {
    const { stdout, exitCode } = runCli([
      fixture.path('input.ts'),
      '--tokenize',
      '--tokenize-format=json',
    ]);
    expect(exitCode).toBe(0);
    const tokens = JSON.parse(stdout);
    expect(tokens.some((token: any) => token.kind === 'const')).toBe(true);
    expect(tokens.some((token: any) => token.kind === '<eof>')).toBe(true);
  });

  test('--profile emits profile report in transpile mode', () => {
    const { stderr, exitCode } = runCli([
      fixture.path('input.ts'),
      '--profile=all',
      '--profile-format=table',
    ]);
    expect(exitCode).toBe(0);
    expect(stderr).toContain('Profile');
  });

  test('존재하지 않는 파일 → 에러', () => {
    const { exitCode, stderr } = runCli(['/nonexistent/file.ts']);
    expect(exitCode).toBe(1);
    expect(stderr.length).toBeGreaterThan(0);
  });

  test('인자 없이 실행 → usage 메시지', () => {
    const { exitCode, stderr } = runCli([]);
    expect(exitCode).toBe(1);
    expect(stderr).toContain('Usage');
  });
});
