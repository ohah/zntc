import {
  describe,
  test,
  expect,
  beforeAll,
  afterAll,
  mkdtempSync,
  writeFileSync,
  rmSync,
  tmpdir,
  join,
  runCli,
} from './helpers';

describe('CLI: arg parsing', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-cli-args-'));
    writeFileSync(join(dir, 'input.ts'), 'export const x: number = 1;');
  });

  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  test('--quotes=single', () => {
    const { exitCode } = runCli([join(dir, 'input.ts'), '--quotes=single']);
    expect(exitCode).toBe(0);
  });

  test('--platform=node', () => {
    const { exitCode } = runCli(['--bundle', join(dir, 'input.ts'), '--platform=node']);
    expect(exitCode).toBe(0);
  });

  test('--platform=react-native', () => {
    const { exitCode } = runCli(['--bundle', join(dir, 'input.ts'), '--platform=react-native']);
    expect(exitCode).toBe(0);
  });

  test('--jsx=automatic + --external react', () => {
    const jsxDir = mkdtempSync(join(tmpdir(), 'zntc-cli-jsx-'));
    writeFileSync(join(jsxDir, 'app.tsx'), 'export default () => <div />;');
    const { stdout, exitCode } = runCli([
      '--bundle',
      join(jsxDir, 'app.tsx'),
      '--jsx=automatic',
      '--external',
      'react/jsx-runtime',
    ]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('jsx-runtime');
    rmSync(jsxDir, { recursive: true, force: true });
  });

  test('--define:KEY=VALUE', () => {
    const defDir = mkdtempSync(join(tmpdir(), 'zntc-cli-define-'));
    writeFileSync(join(defDir, 'input.ts'), 'console.log(process.env.NODE_ENV);');
    const { stdout, exitCode } = runCli([
      '--bundle',
      join(defDir, 'input.ts'),
      '--define:process.env.NODE_ENV="production"',
    ]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('"production"');
    expect(stdout).not.toContain('process.env.NODE_ENV');
    rmSync(defDir, { recursive: true, force: true });
  });

  test('browser bundle defaults process.env.NODE_ENV to production', () => {
    const defDir = mkdtempSync(join(tmpdir(), 'zntc-cli-node-env-'));
    writeFileSync(join(defDir, 'input.ts'), 'console.log(process.env.NODE_ENV);');
    const { stdout, exitCode } = runCli(['--bundle', join(defDir, 'input.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('"production"');
    expect(stdout).not.toContain('process.env.NODE_ENV');
    rmSync(defDir, { recursive: true, force: true });
  });

  test('여러 --external 반복', () => {
    const extDir = mkdtempSync(join(tmpdir(), 'zntc-cli-multi-ext-'));
    writeFileSync(
      join(extDir, 'app.ts'),
      'import a from "react";\nimport b from "lodash";\nconsole.log(a, b);',
    );
    const { stdout, exitCode } = runCli([
      '--bundle',
      join(extDir, 'app.ts'),
      '--external',
      'react',
      '--external',
      'lodash',
    ]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('react');
    expect(stdout).toContain('lodash');
    rmSync(extDir, { recursive: true, force: true });
  });

  test('--jobs=1 (단일 스레드)', () => {
    const { exitCode } = runCli(['--bundle', join(dir, 'input.ts'), '--jobs=1']);
    expect(exitCode).toBe(0);
  });

  test('--help exits before starting subcommands', () => {
    for (const command of ['dev', 'build', 'preview']) {
      const { stdout, stderr, exitCode } = runCli([command, '--help', '--port', '12799'], {
        timeout: 2000,
      });
      expect(exitCode).toBe(0);
      expect(stderr).toBe('');
      expect(stdout).toContain(`Usage: zntc ${command}`);
    }

    const short = runCli(['dev', '-h'], { timeout: 2000 });
    expect(short.exitCode).toBe(0);
    expect(short.stdout).toContain('Usage: zntc dev');
    expect(short.stderr).toBe('');
  });

  test('unknown 옵션 → warning 후 abort', () => {
    const { stderr, exitCode } = runCli([join(dir, 'input.ts'), '--unknown-flag']);
    expect(exitCode).toBe(1);
    expect(stderr).toContain('unknown option');
    expect(stderr).toContain('Usage: zntc');
  });
});

// ─── tsconfig.json 자동 로드 ───
