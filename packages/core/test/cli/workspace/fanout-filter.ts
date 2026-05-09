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
} from '../helpers';

function createWorkspaceFixture() {
  const dir = mkdtempSync(join(tmpdir(), 'zntc-workspace-'));
  writeFileSync(
    join(dir, 'zntc.config.json'),
    JSON.stringify({ format: 'esm', logLevel: 'silent' }),
  );
  mkdirSync(join(dir, 'packages', 'app'), { recursive: true });
  writeFileSync(join(dir, 'packages', 'app', 'package.json'), JSON.stringify({ name: 'my-app' }));
  writeFileSync(join(dir, 'packages', 'app', 'entry.ts'), "console.log('app');");
  writeFileSync(
    join(dir, 'packages', 'app', 'zntc.config.json'),
    JSON.stringify({ entryPoints: ['./entry.ts'], outdir: './dist' }),
  );
  mkdirSync(join(dir, 'packages', 'lib'));
  writeFileSync(join(dir, 'packages', 'lib', 'package.json'), JSON.stringify({ name: 'my-lib' }));
  writeFileSync(join(dir, 'packages', 'lib', 'entry.ts'), "console.log('lib');");
  writeFileSync(
    join(dir, 'packages', 'lib', 'zntc.config.json'),
    JSON.stringify({ entryPoints: ['./entry.ts'], outdir: './out' }),
  );
  mkdirSync(join(dir, 'shared'));
  writeFileSync(join(dir, 'shared', 'x.ts'), "console.log('shared');");
  writeFileSync(
    join(dir, 'zntc.workspace.json'),
    JSON.stringify([
      './packages/app',
      './packages/lib',
      { name: 'inline-shared', entryPoints: ['./shared/x.ts'], outdir: './shared/dist' },
    ]),
  );
  return dir;
}

describe('CLI: workspace (#2111) > fan-out and filters', () => {
  test('3종 형식 동시 사용 — fan-out 빌드', () => {
    const dir = createWorkspaceFixture();
    try {
      const { stderr, exitCode } = runCli(['--bundle'], { cwd: dir });
      expect(exitCode).toBe(0);
      expect(stderr).toContain('3 entries');
      expect(stderr).toContain('workspace: my-app');
      expect(stderr).toContain('workspace: my-lib');
      expect(stderr).toContain('workspace: inline-shared');
      expect(existsSync(join(dir, 'packages', 'app', 'dist'))).toBe(true);
      expect(existsSync(join(dir, 'packages', 'lib', 'out'))).toBe(true);
      expect(existsSync(join(dir, 'shared', 'dist'))).toBe(true);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('--workspace=<name> 필터 — 단일 entry 만 빌드', () => {
    const dir = createWorkspaceFixture();
    try {
      const { stderr, exitCode } = runCli(['--bundle', '--workspace=my-app'], { cwd: dir });
      expect(exitCode).toBe(0);
      expect(stderr).toContain('1 entry');
      expect(stderr).toContain('workspace: my-app');
      expect(existsSync(join(dir, 'packages', 'app', 'dist'))).toBe(true);
      expect(existsSync(join(dir, 'packages', 'lib', 'out'))).toBe(false);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('--workspace=ghost — 매칭 0개 시 에러 + available 노출', () => {
    const dir = createWorkspaceFixture();
    try {
      const { stderr, exitCode } = runCli(['--bundle', '--workspace=ghost'], { cwd: dir });
      expect(exitCode).toBe(1);
      expect(stderr).toContain('matched 0 entries');
      expect(stderr).toContain('my-app');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
