import {
  describe,
  test,
  expect,
  mkdtempSync,
  writeFileSync,
  rmSync,
  mkdirSync,
  tmpdir,
  join,
  runCli,
} from './helpers';

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

  test('--env-prefix=CUSTOM_ 로 prefix 변경', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-env-prefix-'));
    writeFileSync(join(dir, '.env'), 'VITE_NOT_EXPOSED=hidden\nCUSTOM_API=allowed');
    writeFileSync(
      join(dir, 'entry.ts'),
      'console.log(import.meta.env.CUSTOM_API);\nconsole.log(import.meta.env.VITE_NOT_EXPOSED);',
    );
    const { stdout, exitCode } = runCli(
      ['--bundle', '--env-prefix=CUSTOM_', join(dir, 'entry.ts')],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(stdout).toContain('allowed');
    // full import.meta.env 객체 치환 후 미노출 키는 런타임 undefined property 접근으로 남는다.
    expect(stdout).toContain('.VITE_NOT_EXPOSED');
    expect(stdout).not.toContain('"hidden"');
    rmSync(dir, { recursive: true, force: true });
  });

  // ─ 백필: Phase 2-4 (#2106) .env 갭 ───────────────────────────────────────────

  test('--env-dir 으로 다른 디렉토리의 .env 사용', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-env-dir-'));
    mkdirSync(join(dir, 'envs'), { recursive: true });
    writeFileSync(join(dir, 'envs', '.env'), 'VITE_FROM_ENVS_DIR=allowed');
    writeFileSync(join(dir, '.env'), 'VITE_FROM_CWD=ignored'); // cwd 의 .env 는 안 읽힘
    writeFileSync(
      join(dir, 'entry.ts'),
      `console.log(import.meta.env.VITE_FROM_ENVS_DIR);
       console.log(import.meta.env.VITE_FROM_CWD);`,
    );
    const { stdout, exitCode } = runCli(
      ['--bundle', '--env-dir', join(dir, 'envs'), join(dir, 'entry.ts')],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(stdout).toContain('allowed');
    // cwd 의 .env 는 envDir 변경 시 읽히지 않음 — full env 객체에도 포함되지 않는다.
    expect(stdout).toContain('.VITE_FROM_CWD');
    expect(stdout).not.toContain('ignored');
    rmSync(dir, { recursive: true, force: true });
  });

  test('--env-prefix CSV: 여러 prefix 동시 적용', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-env-prefix-csv-'));
    writeFileSync(join(dir, '.env'), 'VITE_A=a\nNEXT_PUBLIC_B=b\nMY_C=c\nUNRELATED=hidden');
    writeFileSync(
      join(dir, 'entry.ts'),
      [
        'console.log(import.meta.env.VITE_A);',
        'console.log(import.meta.env.NEXT_PUBLIC_B);',
        'console.log(import.meta.env.MY_C);',
        'console.log(import.meta.env.UNRELATED);',
      ].join('\n'),
    );
    const { stdout, exitCode } = runCli(
      ['--bundle', '--env-prefix=VITE_,NEXT_PUBLIC_,MY_', join(dir, 'entry.ts')],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(stdout).toContain('"a"');
    expect(stdout).toContain('"b"');
    expect(stdout).toContain('"c"');
    // UNRELATED 는 prefix 매칭 안 되어 full env 객체에도 포함되지 않는다.
    expect(stdout).toContain('.UNRELATED');
    expect(stdout).not.toContain('hidden');
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
