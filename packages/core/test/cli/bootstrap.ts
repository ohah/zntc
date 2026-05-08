import {
  describe,
  test,
  expect,
  cpSync,
  mkdtempSync,
  rmSync,
  mkdirSync,
  tmpdir,
  join,
  resolve,
  BIN_DIR,
  CLI,
  RUNTIME,
  shellQuote,
  readRedirectedProcessOutput,
  runCli,
} from './helpers';

describe('CLI: bootstrap', () => {
  test('prints actionable setup error when built JS dist is missing', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-bootstrap-'));
    try {
      const binDir = join(dir, 'bin');
      mkdirSync(binDir, { recursive: true });
      cpSync(CLI, join(binDir, 'zntc.mjs'));
      cpSync(resolve(BIN_DIR, 'cli-flags.mjs'), join(binDir, 'cli-flags.mjs'));
      cpSync(resolve(BIN_DIR, 'rn-dev-input.mjs'), join(binDir, 'rn-dev-input.mjs'));
      cpSync(resolve(BIN_DIR, 'rn-asset-copy.mjs'), join(binDir, 'rn-asset-copy.mjs'));

      const result = readRedirectedProcessOutput(
        [RUNTIME, join(binDir, 'zntc.mjs'), '--help'].map(shellQuote).join(' '),
      );

      expect(result.exitCode).toBe(1);
      expect(result.stderr).toContain('error: @zntc/core JS bundle is missing');
      expect(result.stderr).toContain('help: run `bun run --cwd packages/core build:js`');
      expect(result.stderr).not.toContain('../index.ts');
      expect(result.stderr).not.toContain('packages/shared/index');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('--test262 without path reports usage instead of running a normal build', () => {
    const result = runCli(['--test262']);
    expect(result.exitCode).toBe(1);
    expect(result.stderr).toContain('Usage');
    expect(result.stderr).not.toContain('unknown option');
  });
});

// ─── Transpile 모드 ───
