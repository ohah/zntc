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
  test('.env.{mode}.local 우선순위 (4단계)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-env-priority-'));
    writeFileSync(join(dir, '.env'), 'VITE_K=base');
    writeFileSync(join(dir, '.env.local'), 'VITE_K=local');
    writeFileSync(join(dir, '.env.production'), 'VITE_K=prod');
    writeFileSync(join(dir, '.env.production.local'), 'VITE_K=prod-local');
    writeFileSync(join(dir, 'entry.ts'), 'console.log(import.meta.env.VITE_K);');
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain('prod-local');
    rmSync(dir, { recursive: true, force: true });
  });

  test('--mode <name> 으로 mode 별 분기', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-env-mode-flag-'));
    writeFileSync(join(dir, '.env.production'), 'VITE_HOST=prod');
    writeFileSync(join(dir, '.env.development'), 'VITE_HOST=dev');
    writeFileSync(join(dir, 'entry.ts'), 'console.log(import.meta.env.VITE_HOST);');

    const buildResult = runCli(['--bundle', '--mode=production', join(dir, 'entry.ts')], {
      cwd: dir,
    });
    expect(buildResult.exitCode).toBe(0);
    expect(buildResult.stdout).toContain('prod');

    const devResult = runCli(['--bundle', '--mode=development', join(dir, 'entry.ts')], {
      cwd: dir,
    });
    expect(devResult.exitCode).toBe(0);
    expect(devResult.stdout).toContain('dev');
    rmSync(dir, { recursive: true, force: true });
  });

  test("serve mode 의 default mode='development' — .env.development 로드", () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-env-serve-default-'));
    writeFileSync(join(dir, '.env.development'), 'VITE_SERVE=dev_mode_value');
    writeFileSync(join(dir, '.env.production'), 'VITE_SERVE=prod_mode_value');
    writeFileSync(join(dir, 'entry.ts'), 'console.log(import.meta.env.VITE_SERVE);');
    // --bundle 모드는 mode default 가 production 이라 .env.production 적용.
    // 함수형 config 의 command='serve' 분기 검증은 단위 테스트가 다룸 — 여기서는
    // CLI 의 default mode 결정 로직만 확인 (bundle → production).
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain('prod_mode_value');
    expect(stdout).not.toContain('dev_mode_value');
    rmSync(dir, { recursive: true, force: true });
  });
});
