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

describe('CLI: bundle runtime polyfill diagnostics', () => {
  test('번들 + runtime-polyfills debug/profile 관측성 출력', () => {
    const polyfillDir = mkdtempSync(join(tmpdir(), 'zntc-cli-runtime-observe-'));
    try {
      writeFileSync(
        join(polyfillDir, 'entry.ts'),
        `globalThis.__VALUE__ = "a".replaceAll("a", "b");`,
      );

      const { stdout, stderr, exitCode } = runCli(
        [
          '--bundle',
          join(polyfillDir, 'entry.ts'),
          '--runtime-polyfills=auto',
          '--runtime-target=ios_saf 12',
          '--profile=graph',
          '--profile-level=detailed',
          '--profile-format=json',
        ],
        { env: { ...process.env, ZNTC_DEBUG: 'runtime_polyfills' } },
      );

      expect(exitCode).toBe(0);
      expect(stdout).toContain('es.string.replace-all');
      expect(stderr).toContain('[runtime_polyfills]');
      expect(stderr).toContain('mode=usage');
      expect(stderr).toContain('feature=string_replace_all');
      expect(stderr).toContain('corejs_module=es.string.replace-all');
      expect(stderr).toContain('"graph.runtime.polyfills.collect"');
      expect(stderr).toContain('"graph.runtime.polyfills.inject"');
    } finally {
      rmSync(polyfillDir, { recursive: true, force: true });
    }
  });

  test('번들 + --runtime-target device name은 actionable error', () => {
    const polyfillDir = mkdtempSync(join(tmpdir(), 'zntc-cli-runtime-device-'));
    try {
      writeFileSync(
        join(polyfillDir, 'entry.ts'),
        `globalThis.__VALUE__ = "a".replaceAll("a", "b");`,
      );

      const { stderr, exitCode } = runCli([
        '--bundle',
        join(polyfillDir, 'entry.ts'),
        '--runtime-polyfills=auto',
        '--runtime-target',
        'iPhone 8',
      ]);

      expect(exitCode).not.toBe(0);
      expect(stderr).toContain('Physical device names are not supported');
      expect(stderr).toContain('ios_saf 12');
    } finally {
      rmSync(polyfillDir, { recursive: true, force: true });
    }
  });

  test('번들 + --runtime-target compact shorthand는 거부', () => {
    const polyfillDir = mkdtempSync(join(tmpdir(), 'zntc-cli-runtime-shorthand-'));
    try {
      writeFileSync(
        join(polyfillDir, 'entry.ts'),
        `globalThis.__VALUE__ = "a".replaceAll("a", "b");`,
      );

      const { stderr, exitCode } = runCli([
        '--bundle',
        join(polyfillDir, 'entry.ts'),
        '--runtime-polyfills=auto',
        '--runtime-target=ios12',
      ]);

      expect(exitCode).not.toBe(0);
      expect(stderr).toContain('Compact runtime target shorthands');
    } finally {
      rmSync(polyfillDir, { recursive: true, force: true });
    }
  });
});
