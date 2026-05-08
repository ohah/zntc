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
  test('.env 의 VITE_* 키가 import.meta.env 로 정적 치환됨', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-env-vite-'));
    writeFileSync(join(dir, '.env'), 'VITE_API=https://prod.example.com');
    writeFileSync(join(dir, 'entry.ts'), 'console.log(import.meta.env.VITE_API);');
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain('https://prod.example.com');
    expect(stdout).not.toContain('import.meta.env.VITE_API');
    rmSync(dir, { recursive: true, force: true });
  });

  test('import.meta.env.MODE / PROD / DEV 자동 주입', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-env-mode-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      `console.log("mode=" + import.meta.env.MODE);
       console.log("prod=" + import.meta.env.PROD);`,
    );
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain('production');
    expect(stdout).toContain('true');
    expect(stdout).not.toContain('import.meta.env.MODE');
    rmSync(dir, { recursive: true, force: true });
  });

  test('shell env 가 .env 파일을 override (CI/배포 시 .env 수정 불필요)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-env-shell-override-'));
    writeFileSync(join(dir, '.env'), 'VITE_HOST=fromFile');
    writeFileSync(join(dir, 'entry.ts'), 'console.log(import.meta.env.VITE_HOST);');
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], {
      cwd: dir,
      env: { ...process.env, VITE_HOST: 'fromShell' },
    });
    expect(exitCode).toBe(0);
    expect(stdout).toContain('fromShell');
    expect(stdout).not.toContain('fromFile');
    rmSync(dir, { recursive: true, force: true });
  });
});
