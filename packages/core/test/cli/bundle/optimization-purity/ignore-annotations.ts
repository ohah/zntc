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

describe('CLI: bundle purity optimization flags > ignore annotations', () => {
  test('번들 + --ignore-annotations preserves @__PURE__ call', () => {
    const annDir = mkdtempSync(join(tmpdir(), 'zntc-cli-ignore-annotations-'));
    try {
      writeFileSync(
        join(annDir, 'entry.ts'),
        "function side(){ console.log('PURE_CALL'); }\n/* @__PURE__ */ side();\nconsole.log('live');",
      );
      const { stdout, stderr, exitCode } = runCli([
        '--bundle',
        join(annDir, 'entry.ts'),
        '--minify-syntax',
        '--ignore-annotations',
      ]);
      expect(exitCode).toBe(0);
      expect(stderr).not.toContain('unknown option');
      expect(stdout).toContain('side()');
      expect(stdout).toContain('PURE_CALL');
    } finally {
      rmSync(annDir, { recursive: true, force: true });
    }
  });
});
