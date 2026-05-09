import { describe, expect, existsSync, join, rmSync, runCli, test } from '../../helpers';
import { createWorkspaceFixture } from './fixture';

describe('CLI: workspace (#2111) > config paths > inline entries', () => {
  test('inline entry 의 outdir 이 root 디렉토리 기준으로 정규화됨', () => {
    const dir = createWorkspaceFixture();
    try {
      runCli(['--bundle', '--workspace=inline-shared'], { cwd: dir });
      expect(existsSync(join(dir, 'shared', 'dist'))).toBe(true);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
