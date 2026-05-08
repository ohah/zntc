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

describe('CLI: bundle format and wrappers > globals', () => {
  test('번들 + --global:SPEC=NAME maps IIFE external globals', () => {
    const globalDir = mkdtempSync(join(tmpdir(), 'zntc-cli-globals-'));
    try {
      writeFileSync(
        join(globalDir, 'entry.ts'),
        "import { useState } from 'react'; console.log(useState);",
      );
      const { stdout, stderr, exitCode } = runCli([
        '--bundle',
        join(globalDir, 'entry.ts'),
        '--format=iife',
        '--global-name=Lib',
        '--external',
        'react',
        '--global:react=React',
      ]);
      expect(exitCode).toBe(0);
      expect(stderr).not.toContain('unknown option');
      expect(stdout).toContain('})(React);');
      expect(stdout).toContain('React.useState');
    } finally {
      rmSync(globalDir, { recursive: true, force: true });
    }
  });
});
