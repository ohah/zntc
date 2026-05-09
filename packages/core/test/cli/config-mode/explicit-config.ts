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
} from '../helpers';

describe('CLI: zntc.config.{mode}.* 자동 머지 > explicit config', () => {
  test('--config <path> 명시 시 mode-specific 자동 탐색 안 함', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-mode-explicit-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('z');");
    writeFileSync(join(dir, 'custom.config.json'), JSON.stringify({ banner: '/* explicit */' }));
    // mode-specific 는 있지만 --config 명시했으므로 무시되어야 함.
    writeFileSync(
      join(dir, 'zntc.config.production.json'),
      JSON.stringify({ banner: '/* should-be-ignored */' }),
    );
    const { stdout, exitCode } = runCli(
      [
        '--bundle',
        '--config',
        join(dir, 'custom.config.json'),
        '--mode=production',
        join(dir, 'entry.ts'),
      ],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(stdout).toContain('/* explicit */');
    expect(stdout).not.toContain('/* should-be-ignored */');
    rmSync(dir, { recursive: true, force: true });
  });
});
