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

describe('CLI: bundle syntax and targets > target and browserslist', () => {
  test('번들 + --target=es5 (ES 다운레벨)', () => {
    const arrowDir = mkdtempSync(join(tmpdir(), 'zntc-cli-target-'));
    try {
      writeFileSync(join(arrowDir, 'entry.ts'), 'const fn = () => 42; console.log(fn());');
      const { stdout, exitCode } = runCli(['--bundle', join(arrowDir, 'entry.ts'), '--target=es5']);
      expect(exitCode).toBe(0);
      expect(stdout).not.toContain('=>');
    } finally {
      rmSync(arrowDir, { recursive: true, force: true });
    }
  });

  test('번들 + --browserslist (target 보다 우선, modern 쿼리는 arrow 보존)', () => {
    const blDir = mkdtempSync(join(tmpdir(), 'zntc-cli-browserslist-'));
    try {
      writeFileSync(join(blDir, 'entry.ts'), 'const fn = () => 42; console.log(fn());');
      const { stdout, exitCode } = runCli([
        '--bundle',
        join(blDir, 'entry.ts'),
        '--target=es5',
        '--browserslist=last 1 chrome version',
      ]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('=>');
    } finally {
      rmSync(blDir, { recursive: true, force: true });
    }
  });
});
