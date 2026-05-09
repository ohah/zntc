import { readdirSync } from 'node:fs';
import { describe, expect, join, readFileSync, rmSync, runCli, test } from '../../helpers';
import { createWorkspaceFixture } from './fixture';

describe('CLI: workspace (#2111) > config paths > root inheritance', () => {
  test('root config 상속 — entry 가 root format=esm 적용받음', () => {
    const dir = createWorkspaceFixture();
    try {
      runCli(['--bundle', '--workspace=my-app'], { cwd: dir });
      const distFiles = readdirSync(join(dir, 'packages', 'app', 'dist'));
      const jsFile = distFiles.find((file) => file.endsWith('.js'));
      expect(jsFile).toBeDefined();
      const out = readFileSync(join(dir, 'packages', 'app', 'dist', jsFile!), 'utf8');
      expect(out).toContain('app');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
