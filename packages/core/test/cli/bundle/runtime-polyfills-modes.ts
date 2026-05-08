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
} from '../helpers';

describe('CLI: bundle runtime polyfill modes', () => {
  test('번들 + --runtime-polyfills=auto + --runtime-target', () => {
    const polyfillDir = mkdtempSync(join(tmpdir(), 'zntc-cli-runtime-polyfills-'));
    try {
      writeFileSync(
        join(polyfillDir, 'entry.ts'),
        `globalThis.__VALUE__ = "a".replaceAll("a", "b");`,
      );

      const { stdout, stderr, exitCode } = runCli([
        '--bundle',
        join(polyfillDir, 'entry.ts'),
        '--runtime-polyfills=auto',
        '--runtime-target=ios_saf 12',
      ]);

      expect(exitCode).toBe(0);
      expect(stderr).toBe('');
      expect(stdout).toContain('es.string.replace-all');
    } finally {
      rmSync(polyfillDir, { recursive: true, force: true });
    }
  });

  test('번들 + --runtime-polyfills=usage 는 graph usage alias로 동작', () => {
    const polyfillDir = mkdtempSync(join(tmpdir(), 'zntc-cli-runtime-usage-'));
    try {
      writeFileSync(
        join(polyfillDir, 'entry.ts'),
        `globalThis.__VALUE__ = new Map([["x", 1]]).get("x");`,
      );

      const { stdout, stderr, exitCode } = runCli([
        '--bundle',
        join(polyfillDir, 'entry.ts'),
        '--runtime-polyfills=usage',
        '--runtime-target=safari 5',
      ]);

      expect(exitCode).toBe(0);
      expect(stderr).toBe('');
      expect(stdout).toContain('es.map');
    } finally {
      rmSync(polyfillDir, { recursive: true, force: true });
    }
  });

  test('번들 + --runtime-polyfills=off 는 collector/profile/debug 경로를 실행하지 않음', () => {
    const polyfillDir = mkdtempSync(join(tmpdir(), 'zntc-cli-runtime-off-observe-'));
    try {
      writeFileSync(
        join(polyfillDir, 'entry.ts'),
        `globalThis.__VALUE__ = "a".replaceAll("a", "b");`,
      );

      const { stdout, stderr, exitCode } = runCli(
        [
          '--bundle',
          join(polyfillDir, 'entry.ts'),
          '--runtime-polyfills=off',
          '--runtime-target=ios_saf 12',
          '--profile=graph',
          '--profile-level=detailed',
          '--profile-format=json',
        ],
        { env: { ...process.env, ZNTC_DEBUG: 'runtime_polyfills' } },
      );

      expect(exitCode).toBe(0);
      expect(stdout).not.toContain('es.string.replace-all');
      expect(stderr).not.toContain('[runtime_polyfills]');
      expect(stderr).not.toContain('graph.runtime.polyfills');
    } finally {
      rmSync(polyfillDir, { recursive: true, force: true });
    }
  });
});
