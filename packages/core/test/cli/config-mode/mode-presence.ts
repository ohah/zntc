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

describe('CLI: zntc.config.{mode}.* 자동 머지 > mode presence', () => {
  test('mode-specific 만 존재 (base 부재) — mode config 단독 사용', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-mode-only-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('x');");
    writeFileSync(
      join(dir, 'zntc.config.staging.json'),
      JSON.stringify({ banner: '/* staging-only */' }),
    );
    const { stdout, exitCode } = runCli(['--bundle', '--mode=staging', join(dir, 'entry.ts')], {
      cwd: dir,
    });
    expect(exitCode).toBe(0);
    expect(stdout).toContain('/* staging-only */');
    rmSync(dir, { recursive: true, force: true });
  });

  test('mode 미매치: base 만 적용', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-mode-mismatch-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('y');");
    writeFileSync(join(dir, 'zntc.config.json'), JSON.stringify({ banner: '/* base */' }));
    writeFileSync(
      join(dir, 'zntc.config.production.json'),
      JSON.stringify({ banner: '/* prod-only */' }),
    );
    // --mode=development → .production config 무시.
    const { stdout, exitCode } = runCli(['--bundle', '--mode=development', join(dir, 'entry.ts')], {
      cwd: dir,
    });
    expect(exitCode).toBe(0);
    expect(stdout).toContain('/* base */');
    expect(stdout).not.toContain('/* prod-only */');
    rmSync(dir, { recursive: true, force: true });
  });
});
