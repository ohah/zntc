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

describe('CLI: bundle syntax and targets > JSX in JS', () => {
  test('--jsx-in-js — .js 파일에서도 JSX 파싱 (classic 모드 — runtime resolve 회피)', () => {
    const jsxDir = mkdtempSync(join(tmpdir(), 'zntc-cli-jsx-in-js-'));
    try {
      writeFileSync(
        join(jsxDir, 'entry.js'),
        'function React_createElement() {} const el = <div>OK</div>; console.log(el);',
      );
      const { stdout, exitCode } = runCli([
        '--bundle',
        join(jsxDir, 'entry.js'),
        '--jsx-in-js',
        '--jsx=classic',
        '--jsx-factory=React_createElement',
      ]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('React_createElement');
      expect(stdout).not.toContain('<div>');
    } finally {
      rmSync(jsxDir, { recursive: true, force: true });
    }
  });
});
