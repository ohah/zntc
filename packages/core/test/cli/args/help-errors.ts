import {
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  runCli,
  test,
  tmpdir,
  writeFileSync,
} from '../helpers';

describe('CLI: arg parsing > help and errors', () => {
  test('--help exits before starting subcommands', () => {
    for (const command of ['dev', 'build', 'preview']) {
      const { stdout, stderr, exitCode } = runCli([command, '--help', '--port', '12799'], {
        timeout: 2000,
      });
      expect(exitCode).toBe(0);
      expect(stderr).toBe('');
      expect(stdout).toContain(`Usage: zntc ${command}`);
    }

    const short = runCli(['dev', '-h'], { timeout: 2000 });
    expect(short.exitCode).toBe(0);
    expect(short.stdout).toContain('Usage: zntc dev');
    expect(short.stderr).toBe('');
  });

  test('unknown 옵션 → warning 후 abort', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-args-'));
    try {
      writeFileSync(join(dir, 'input.ts'), 'export const x: number = 1;');
      const { stderr, exitCode } = runCli([join(dir, 'input.ts'), '--unknown-flag']);
      expect(exitCode).toBe(1);
      expect(stderr).toContain('unknown option');
      expect(stderr).toContain('Usage: zntc');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
