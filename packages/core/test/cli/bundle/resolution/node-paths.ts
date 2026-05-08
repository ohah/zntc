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

describe('CLI: bundle resolution options > node paths', () => {
  test('번들 + --node-paths=<csv> 추가 lookup directory에서 bare specifier resolve', () => {
    const npDir = mkdtempSync(join(tmpdir(), 'zntc-cli-node-paths-'));
    try {
      const vendor = join(npDir, 'vendor');
      mkdirSync(join(vendor, 'pkg'), { recursive: true });
      writeFileSync(join(vendor, 'pkg', 'package.json'), JSON.stringify({ main: 'index.js' }));
      writeFileSync(join(vendor, 'pkg', 'index.js'), "export const value = 'NODE_PATH_VALUE';");
      writeFileSync(join(npDir, 'entry.ts'), "import { value } from 'pkg'; console.log(value);");
      const { stdout, stderr, exitCode } = runCli([
        '--bundle',
        join(npDir, 'entry.ts'),
        `--node-paths=${vendor}`,
      ]);
      expect(exitCode).toBe(0);
      expect(stderr).not.toContain('unknown option');
      expect(stdout).toContain('NODE_PATH_VALUE');
    } finally {
      rmSync(npDir, { recursive: true, force: true });
    }
  });
});
