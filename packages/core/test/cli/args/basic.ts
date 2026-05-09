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
});
