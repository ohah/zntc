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

describe('CLI: bundle purity optimization flags > JSX side effects', () => {
  test('번들 + --jsx-side-effects preserves unused JSX expression', () => {
    const jsxDir = mkdtempSync(join(tmpdir(), 'zntc-cli-jsx-side-effects-'));
    try {
      writeFileSync(
        join(jsxDir, 'entry.tsx'),
        [
          'const React = { createElement(type) { console.log(type); } };',
          '<div />;',
          "console.log('live');",
        ].join('\n'),
      );
      const { stdout, stderr, exitCode } = runCli([
        '--bundle',
        join(jsxDir, 'entry.tsx'),
        '--minify-syntax',
        '--jsx-side-effects',
      ]);
      expect(exitCode).toBe(0);
      expect(stderr).not.toContain('unknown option');
      expect(stdout).toContain('React.createElement');
    } finally {
      rmSync(jsxDir, { recursive: true, force: true });
    }
  });
});
