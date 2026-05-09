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

describe('CLI: zntc.config BuildOptions > runtime polyfills', () => {
  test('zntc.config.json 의 runtimePolyfills 가 적용됨', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-config-runtime-polyfills-'));
    writeFileSync(join(dir, 'entry.ts'), `globalThis.__VALUE__ = "a".replaceAll("a", "b");`);
    writeFileSync(
      join(dir, 'zntc.config.json'),
      JSON.stringify({
        entryPoints: ['./entry.ts'],
        format: 'iife',
        runtimePolyfills: { mode: 'auto', targets: ['ios_saf 12'] },
      }),
    );
    const { stdout, stderr, exitCode } = runCli(['--bundle'], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stderr).toBe('');
    expect(stdout).toContain('es.string.replace-all');
    rmSync(dir, { recursive: true, force: true });
  });
});
