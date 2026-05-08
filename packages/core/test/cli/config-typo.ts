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

describe('CLI: zntc.config typo 검출', () => {
  test("typo 한 키에 대해 stderr 에 'did you mean ...?' 경고", () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-typo-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('hi');");
    // 'minfy' (typo) — 'minify' 제안되어야 함.
    writeFileSync(join(dir, 'zntc.config.json'), JSON.stringify({ minfy: true }));
    const { stderr, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stderr).toContain("unknown config key 'minfy'");
    expect(stderr).toContain("did you mean 'minify'");
    rmSync(dir, { recursive: true, force: true });
  });

  test('정확한 키만 있으면 경고 없음', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-no-typo-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('hi');");
    writeFileSync(join(dir, 'zntc.config.json'), JSON.stringify({ format: 'esm', minify: true }));
    const { stderr, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stderr).not.toContain('unknown config key');
    rmSync(dir, { recursive: true, force: true });
  });

  test('--log-level=silent: 경고 출력 안 함', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-typo-silent-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('hi');");
    writeFileSync(join(dir, 'zntc.config.json'), JSON.stringify({ minfy: true }));
    const { stderr, exitCode } = runCli(['--bundle', '--log-level=silent', join(dir, 'entry.ts')], {
      cwd: dir,
    });
    expect(exitCode).toBe(0);
    expect(stderr).not.toContain('unknown config key');
    rmSync(dir, { recursive: true, force: true });
  });

  test("거리 초과 unknown 키: 'did you mean' 없이 단순 경고", () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-typo-far-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('hi');");
    writeFileSync(join(dir, 'zntc.config.json'), JSON.stringify({ kubernetes: true }));
    const { stderr, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stderr).toContain("unknown config key 'kubernetes'");
    expect(stderr).not.toContain('did you mean');
    rmSync(dir, { recursive: true, force: true });
  });

  test('typo 가 있어도 빌드는 성공 (warning, not error)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-typo-warn-not-error-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('OK');");
    writeFileSync(join(dir, 'zntc.config.json'), JSON.stringify({ minfy: true, format: 'esm' }));
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain('OK');
    rmSync(dir, { recursive: true, force: true });
  });
});

// ─── #2111: zntc.workspace.ts (Vitest 식 모노레포) ───
