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

describe('CLI: zntc.config discovery', () => {
  test('zntc.config.ts 의 entryPoints 가 자동 적용됨', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-config-merge-'));
    writeFileSync(join(dir, 'src.ts'), "export const HIT = 'CONFIG_ENTRY_OK';");
    writeFileSync(
      join(dir, 'zntc.config.ts'),
      `export default { entryPoints: ["${join(dir, 'src.ts').replace(/\\/g, '/')}"] };`,
    );
    const { stdout, exitCode } = runCli(['--bundle'], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain('CONFIG_ENTRY_OK');
    rmSync(dir, { recursive: true, force: true });
  });

  test('config 부재 시 CLI 단독으로 정상 빌드 (회귀 방지)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-no-config-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('NO_CONFIG_OK');");
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain('NO_CONFIG_OK');
    rmSync(dir, { recursive: true, force: true });
  });

  test('config 컴파일 실패 시 CLI 가 명확한 에러로 exit 1', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-broken-config-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('x');");
    writeFileSync(
      join(dir, 'zntc.config.ts'),
      "export default { format: 'esm'  // 닫는 brace 없음",
    );
    const { stderr, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(1);
    expect(stderr).toContain('failed to load config');
    rmSync(dir, { recursive: true, force: true });
  });
});
