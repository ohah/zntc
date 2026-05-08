import {
  describe,
  test,
  expect,
  existsSync,
  mkdirSync,
  writeFileSync,
  rmSync,
  join,
  resolve,
  runCli,
} from '../helpers';
import { useBundleFixture } from './fixture';

describe('CLI: bundle output files', () => {
  const fixture = useBundleFixture();

  test('번들 + --sourcemap + -o', () => {
    const outFile = join(fixture.dir(), 'bundle-sm.js');
    const { exitCode } = runCli(['--bundle', fixture.entryPoint(), '--sourcemap', '-o', outFile]);
    expect(exitCode).toBe(0);
    expect(existsSync(outFile + '.map')).toBe(true);
  });

  test('번들 + --metafile', () => {
    const outDir = join(fixture.dir(), 'meta-out');
    const { exitCode } = runCli([
      '--bundle',
      fixture.entryPoint(),
      '--metafile',
      '--outdir',
      outDir,
    ]);
    expect(exitCode).toBe(0);
    expect(existsSync(resolve('meta.json'))).toBe(true);
    rmSync(resolve('meta.json'), { force: true });
  });

  test('번들 + --profile emits profile report', () => {
    const { stderr, exitCode } = runCli([
      '--bundle',
      fixture.entryPoint(),
      '--profile=all',
      '--profile-format=table',
      '-o',
      join(fixture.dir(), 'profile-bundle.js'),
    ]);
    expect(exitCode).toBe(0);
    expect(stderr).not.toContain('unknown option');
    expect(stderr).toContain('=== ZNTC Profile ===');
  });

  test('번들 + --clean (outdir 정리 후 빌드)', () => {
    const outDir = join(fixture.dir(), 'clean-out');
    mkdirSync(outDir, { recursive: true });
    writeFileSync(join(outDir, 'stale.js'), 'stale');

    const { exitCode } = runCli(['--bundle', fixture.entryPoint(), '--outdir', outDir, '--clean']);
    expect(exitCode).toBe(0);
    expect(existsSync(join(outDir, 'stale.js'))).toBe(false);
  });
});
