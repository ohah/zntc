import {
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  runCli,
  test,
  tmpdir,
  writeFileSync,
} from '../helpers';

function createCliInput() {
  const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-args-'));
  writeFileSync(join(dir, 'input.ts'), 'export const x: number = 1;');
  return dir;
}

describe('CLI: arg parsing > basic flags', () => {
  test('--quotes=single', () => {
    const dir = createCliInput();
    try {
      const { exitCode } = runCli([join(dir, 'input.ts'), '--quotes=single']);
      expect(exitCode).toBe(0);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('--platform=node', () => {
    const dir = createCliInput();
    try {
      const { exitCode } = runCli(['--bundle', join(dir, 'input.ts'), '--platform=node']);
      expect(exitCode).toBe(0);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('--platform=react-native', () => {
    const dir = createCliInput();
    try {
      const { exitCode } = runCli(['--bundle', join(dir, 'input.ts'), '--platform=react-native']);
      expect(exitCode).toBe(0);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('--jobs=1 (단일 스레드)', () => {
    const dir = createCliInput();
    try {
      const { exitCode } = runCli(['--bundle', join(dir, 'input.ts'), '--jobs=1']);
      expect(exitCode).toBe(0);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('--dev', () => {
    const dir = createCliInput();
    try {
      const { exitCode } = runCli(['--bundle', join(dir, 'input.ts'), '--dev']);
      expect(exitCode).toBe(0);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('--global-identifier / --polyfill / --run-before-main / --watch-folder / --watch-include / --watch-exclude (반복 가능)', () => {
    const dir = createCliInput();
    writeFileSync(join(dir, 'poly.ts'), 'globalThis.__POLY__ = 1;');
    writeFileSync(join(dir, 'pre.ts'), 'globalThis.__PRE__ = 1;');
    try {
      const { exitCode, stderr } = runCli([
        '--bundle',
        join(dir, 'input.ts'),
        '--global-identifier=__FOO',
        '--global-identifier=__BAR',
        `--polyfill=${join(dir, 'poly.ts')}`,
        `--run-before-main=${join(dir, 'pre.ts')}`,
        `--watch-folder=${dir}`,
        '--watch-include=**/*.ts',
        '--watch-exclude=**/*.test.ts',
      ]);
      expect(exitCode).toBe(0);
      expect(stderr).not.toContain('unknown CLI flag');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
