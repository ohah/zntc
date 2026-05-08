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
} from './helpers';

describe('CLI: zntc.config.{mode}.* 자동 머지', () => {
  test('mode-specific config 가 base 를 override', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-mode-cfg-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('hi');");
    writeFileSync(join(dir, 'zntc.config.json'), JSON.stringify({ banner: '/* base */' }));
    writeFileSync(
      join(dir, 'zntc.config.production.json'),
      JSON.stringify({ banner: '/* prod-mode */' }),
    );
    const { stdout, exitCode } = runCli(['--bundle', '--mode=production', join(dir, 'entry.ts')], {
      cwd: dir,
    });
    expect(exitCode).toBe(0);
    expect(stdout).toContain('/* prod-mode */');
    expect(stdout).not.toContain('/* base */');
    rmSync(dir, { recursive: true, force: true });
  });

  test('base + mode 머지: 둘 다 정의된 키 + 한쪽만 정의된 키', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-mode-merge-'));
    writeFileSync(join(dir, 'entry.ts'), 'console.log(__VER__, __BUILD__);');
    writeFileSync(
      join(dir, 'zntc.config.json'),
      JSON.stringify({
        define: { __VER__: '"v1"', __BUILD__: '"prod"' },
      }),
    );
    writeFileSync(
      join(dir, 'zntc.config.production.json'),
      JSON.stringify({
        define: { __BUILD__: '"prod-override"' },
      }),
    );
    const { stdout, exitCode } = runCli(['--bundle', '--mode=production', join(dir, 'entry.ts')], {
      cwd: dir,
    });
    expect(exitCode).toBe(0);
    // base 의 __VER__ 그대로, mode 의 __BUILD__ override
    expect(stdout).toContain('"v1"');
    expect(stdout).toContain('"prod-override"');
    expect(stdout).not.toContain('"prod"' + ')'); // 기존 prod 값 미사용
    rmSync(dir, { recursive: true, force: true });
  });

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

// ─── Typo "did you mean?" (#2109 / Phase 3-2) ─────────────────────────────────
