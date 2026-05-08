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

describe('CLI: .env 자동 로드', () => {
  test('.env trailing newline 유무 무관 (보수적 파서)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-env-nlEOF-'));
    // 마지막 줄에 newline 없음.
    writeFileSync(join(dir, '.env'), 'VITE_LAST=foo');
    writeFileSync(join(dir, 'entry.ts'), 'console.log(import.meta.env.VITE_LAST);');
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain('foo');
    rmSync(dir, { recursive: true, force: true });
  });

  test('.env CRLF 줄바꿈도 정상 파싱', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-env-crlf-'));
    writeFileSync(join(dir, '.env'), 'VITE_A=a\r\nVITE_B=b\r\n');
    writeFileSync(
      join(dir, 'entry.ts'),
      'console.log(import.meta.env.VITE_A, import.meta.env.VITE_B);',
    );
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain('"a"');
    expect(stdout).toContain('"b"');
    rmSync(dir, { recursive: true, force: true });
  });
});
