import {
  describe,
  expect,
  join,
  mkdirSync,
  mkdtempSync,
  rmSync,
  runCli,
  test,
  tmpdir,
  writeFileSync,
} from '../helpers';

describe('CLI: .env 자동 로드', () => {
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

  // 백필: Phase 2-4 (#2106) .env 갭

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
});
