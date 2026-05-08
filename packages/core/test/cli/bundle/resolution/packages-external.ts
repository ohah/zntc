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

describe('CLI: bundle resolution options > packages external', () => {
  test('번들 + --packages=external 은 bare package만 external 처리', () => {
    const extDir = mkdtempSync(join(tmpdir(), 'zntc-cli-packages-ext-'));
    try {
      writeFileSync(
        join(extDir, 'app.ts'),
        'import React from "react";\nimport { local } from "./local";\nconsole.log(React, local);',
      );
      writeFileSync(join(extDir, 'local.ts'), "export const local = 'LOCAL_INCLUDED';");
      const { stdout, stderr, exitCode } = runCli([
        '--bundle',
        join(extDir, 'app.ts'),
        '--packages=external',
        '--format=esm',
      ]);
      expect(exitCode).toBe(0);
      expect(stderr).not.toContain('unknown option');
      expect(stdout).toContain('"react"');
      expect(stdout).toContain('LOCAL_INCLUDED');
      expect(stdout).not.toContain('from "./local"');
    } finally {
      rmSync(extDir, { recursive: true, force: true });
    }
  });
});
