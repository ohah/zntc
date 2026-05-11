import {
  describe,
  test,
  expect,
  cpSync,
  mkdtempSync,
  rmSync,
  mkdirSync,
  readdirSync,
  tmpdir,
  join,
  resolve,
  BIN_DIR,
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
      for (const f of readdirSync(BIN_DIR)) {
        if (f.endsWith('.mjs')) cpSync(resolve(BIN_DIR, f), join(binDir, f));
      }

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
