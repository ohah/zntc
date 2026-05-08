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

describe('CLI: bundle syntax and targets > verbatim module syntax', () => {
  test('--verbatim-module-syntax — flag 가 NAPI 까지 reach (실 동작 미구현은 별도)', () => {
    const vmsDir = mkdtempSync(join(tmpdir(), 'zntc-cli-vms-'));
    try {
      writeFileSync(
        join(vmsDir, 'entry.ts'),
        "import type { X } from './t.ts';\nimport { y } from './t.ts';\nconsole.log(y);",
      );
      writeFileSync(join(vmsDir, 't.ts'), 'export type X = number;\nexport const y = 1;');
      const { stdout, exitCode } = runCli([join(vmsDir, 'entry.ts'), '--verbatim-module-syntax']);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('import');
    } finally {
      rmSync(vmsDir, { recursive: true, force: true });
    }
  });
});
