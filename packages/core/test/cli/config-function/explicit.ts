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

describe('CLI: 함수형 config + --config flag', () => {
  test('--config <path>: 명시 경로의 config 사용 (자동 탐색 우회)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-explicit-cfg-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('hi');");
    // 기본 자동 탐색 대상 — 사용 안 됨을 검증
    writeFileSync(join(dir, 'zntc.config.ts'), `export default { banner: "/* AUTO */" };`);
    // 명시 config — 이게 사용되어야 함
    writeFileSync(join(dir, 'custom.config.ts'), `export default { banner: "/* CUSTOM */" };`);
    const { stdout, exitCode } = runCli(
      ['--bundle', '--config', join(dir, 'custom.config.ts'), join(dir, 'entry.ts')],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(stdout).toContain('/* CUSTOM */');
    expect(stdout).not.toContain('/* AUTO */');
    rmSync(dir, { recursive: true, force: true });
  });

  test('--config=<path> (= form) 도 동작', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cfg-eq-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('hi');");
    writeFileSync(join(dir, 'alt.config.ts'), `export default { banner: "/* ALT */" };`);
    const { stdout, exitCode } = runCli(
      ['--bundle', `--config=${join(dir, 'alt.config.ts')}`, join(dir, 'entry.ts')],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(stdout).toContain('/* ALT */');
    rmSync(dir, { recursive: true, force: true });
  });

  test('--config 가 .ts 형식도 정상 로드', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cfg-explicit-ts-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('hi');");
    writeFileSync(
      join(dir, 'alt.config.ts'),
      `export default { banner: "/* TS_CFG */" as const };`,
    );
    const { stdout, exitCode } = runCli(
      ['--bundle', '--config', join(dir, 'alt.config.ts'), join(dir, 'entry.ts')],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(stdout).toContain('/* TS_CFG */');
    rmSync(dir, { recursive: true, force: true });
  });
});
