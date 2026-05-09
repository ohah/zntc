import {
  describe,
  expect,
  existsSync,
  join,
  mkdirSync,
  mkdtempSync,
  rmSync,
  runCli,
  test,
  tmpdir,
  writeFileSync,
} from '../../helpers';
import { createWorkspaceFixture } from './fixture';

describe('CLI: workspace (#2111) > config paths > explicit config', () => {
  test('--workspace-config <path> 명시 — 자동 탐색 우회', () => {
    const altDir = mkdtempSync(join(tmpdir(), 'zntc-workspace-explicit-'));
    try {
      mkdirSync(join(altDir, 'src'));
      writeFileSync(join(altDir, 'src', 'main.ts'), "console.log('explicit');");
      const wsPath = join(altDir, 'custom.workspace.json');
      writeFileSync(
        wsPath,
        JSON.stringify([{ name: 'explicit', entryPoints: ['./src/main.ts'], outdir: './out' }]),
      );
      const { exitCode } = runCli(
        ['--bundle', `--workspace-config=${wsPath}`, '--log-level=silent'],
        { cwd: altDir },
      );
      expect(exitCode).toBe(0);
      expect(existsSync(join(altDir, 'out'))).toBe(true);
    } finally {
      rmSync(altDir, { recursive: true, force: true });
    }
  });

  test('--workspace-config 가 없는 파일이면 에러', () => {
    const dir = createWorkspaceFixture();
    try {
      const { stderr, exitCode } = runCli(
        ['--bundle', '--workspace-config=/tmp/zntc-nonexistent-workspace.ts'],
        { cwd: dir },
      );
      expect(exitCode).toBe(1);
      expect(stderr).toContain('file not found');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
