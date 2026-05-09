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

describe('CLI: zntc.config.{mode}.* 자동 머지 > TypeScript config', () => {
  test('mode-specific config TS 형식도 동작', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-mode-ts-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('q');");
    writeFileSync(
      join(dir, 'zntc.config.production.ts'),
      `export default { banner: "/* TS_PROD */" as const };`,
    );
    const { stdout, exitCode } = runCli(['--bundle', '--mode=production', join(dir, 'entry.ts')], {
      cwd: dir,
    });
    expect(exitCode).toBe(0);
    expect(stdout).toContain('/* TS_PROD */');
    rmSync(dir, { recursive: true, force: true });
  });
});
