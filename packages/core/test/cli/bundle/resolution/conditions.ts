import {
  describe,
  test,
  expect,
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  rmSync,
  tmpdir,
  join,
  runCli,
} from '../../helpers';

describe('CLI: bundle resolution options > conditions', () => {
  test('번들 + --conditions=<csv> custom exports condition 적용', () => {
    const condDir = mkdtempSync(join(tmpdir(), 'zntc-cli-conditions-'));
    try {
      mkdirSync(join(condDir, 'node_modules', 'pkg'), { recursive: true });
      writeFileSync(
        join(condDir, 'node_modules', 'pkg', 'package.json'),
        JSON.stringify({
          name: 'pkg',
          exports: {
            '.': {
              custom: './custom.js',
              default: './default.js',
            },
          },
        }),
      );
      writeFileSync(
        join(condDir, 'node_modules', 'pkg', 'custom.js'),
        "export const value = 'custom';",
      );
      writeFileSync(
        join(condDir, 'node_modules', 'pkg', 'default.js'),
        "export const value = 'default';",
      );
      writeFileSync(join(condDir, 'entry.ts'), "import { value } from 'pkg'; console.log(value);");
      const { stdout, stderr, exitCode } = runCli([
        '--bundle',
        join(condDir, 'entry.ts'),
        '--conditions=custom',
      ]);
      expect(exitCode).toBe(0);
      expect(stderr).not.toContain('unknown option');
      expect(stdout).toContain('custom');
      expect(stdout).not.toContain('default');
    } finally {
      rmSync(condDir, { recursive: true, force: true });
    }
  });
});
