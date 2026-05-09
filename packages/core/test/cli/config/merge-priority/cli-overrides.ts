import {
  describe,
  test,
  expect,
  mkdtempSync,
  writeFileSync,
  rmSync,
  tmpdir,
  join,
  runCli,
} from '../../helpers';

describe('CLI: zntc.config merge priority > CLI overrides', () => {
  test('CLI 가 config 를 override (CLI > config 우선순위)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-config-override-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('cli_wins');");
    writeFileSync(
      join(dir, 'zntc.config.json'),
      JSON.stringify({ format: 'iife', globalName: 'CFG_NAME' }),
    );
    const { stdout, exitCode } = runCli(
      ['--bundle', '--global-name=CLI_NAME', join(dir, 'entry.ts')],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(stdout).toContain('CLI_NAME');
    expect(stdout).not.toContain('CFG_NAME');
    rmSync(dir, { recursive: true, force: true });
  });
});
