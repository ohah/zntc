import {
  describe,
  expect,
  join,
  mkdirSync,
  mkdtempSync,
  rmSync,
  runCli,
  test,
  tmpdir,
  writeFileSync,
} from '../helpers';

describe('CLI: Vite-style app builder > public collision', () => {
  test('public output collision fails deterministically', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-public-collision-'));
    try {
      mkdirSync(join(dir, 'src'), { recursive: true });
      mkdirSync(join(dir, 'public'), { recursive: true });
      writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
      writeFileSync(join(dir, 'src', 'main.ts'), 'console.log(1);');
      writeFileSync(join(dir, 'public', 'index.html'), 'collision');

      const outdir = join(dir, 'dist');
      const { exitCode, stderr } = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
      expect(exitCode).toBe(1);
      expect(stderr).toContain('PublicDirCollision');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
