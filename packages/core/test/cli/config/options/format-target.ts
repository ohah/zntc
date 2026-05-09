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

describe('CLI: zntc.config BuildOptions > format and target', () => {
  test('config 의 format 머지 — CLI 미지정 시 적용', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cfg-format-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('hi');");
    writeFileSync(
      join(dir, 'zntc.config.json'),
      JSON.stringify({ format: 'iife', globalName: 'G' }),
    );
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain('var G');
    rmSync(dir, { recursive: true, force: true });
  });

  test('config 의 target 머지 — CLI 미지정 시 적용', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cfg-target-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      'const arr = [1, 2, 3];\nconst [a, ...rest] = arr;\nconsole.log(a, rest);',
    );
    writeFileSync(join(dir, 'zntc.config.json'), JSON.stringify({ target: 'es5' }));
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain('.slice(');
    rmSync(dir, { recursive: true, force: true });
  });
});
