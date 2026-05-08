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
  test('--config 명시 + 파일 부재 시 명확한 에러로 exit 1', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cfg-missing-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('x');");
    const { stderr, exitCode } = runCli(
      ['--bundle', '--config', join(dir, 'nope.config.ts'), join(dir, 'entry.ts')],
      { cwd: dir },
    );
    expect(exitCode).toBe(1);
    expect(stderr).toContain('file not found');
    rmSync(dir, { recursive: true, force: true });
  });

  test('함수형 config throw → exit 1 + 에러 메시지', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-fn-throw-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('x');");
    writeFileSync(
      join(dir, 'zntc.config.ts'),
      `export default () => { throw new Error("BOOM_FROM_CONFIG"); };`,
    );
    const { stderr, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(1);
    expect(stderr).toContain('BOOM_FROM_CONFIG');
    rmSync(dir, { recursive: true, force: true });
  });

  test('함수형 config 가 객체 아닌 값 반환 → exit 1', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-fn-bad-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('x');");
    writeFileSync(join(dir, 'zntc.config.ts'), `export default () => "not an object";`);
    const { stderr, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(1);
    expect(stderr).toMatch(/functional config must return an object/);
    rmSync(dir, { recursive: true, force: true });
  });
});
