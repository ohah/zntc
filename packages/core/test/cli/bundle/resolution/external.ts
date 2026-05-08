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

describe('CLI: bundle resolution options > external', () => {
  test('번들 + --external', () => {
    const extDir = mkdtempSync(join(tmpdir(), 'zntc-cli-ext-'));
    try {
      writeFileSync(join(extDir, 'app.ts'), 'import React from "react";\nconsole.log(React);');
      const { stdout, exitCode } = runCli([
        '--bundle',
        join(extDir, 'app.ts'),
        '--external',
        'react',
      ]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('react');
    } finally {
      rmSync(extDir, { recursive: true, force: true });
    }
  });
});
