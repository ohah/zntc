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
} from '../../helpers';

describe('CLI: zntc.config BuildOptions > minify', () => {
  test('zntc.config.ts 의 minify 가 적용됨', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-config-minify-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      'const someLongName = 1; const anotherLongName = 2; console.log(someLongName + anotherLongName);',
    );
    writeFileSync(join(dir, 'zntc.config.ts'), `export default { minify: true };`);
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).not.toContain('someLongName');
    rmSync(dir, { recursive: true, force: true });
  });
});
