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
import { useTranspileFixture } from './fixture';

describe('CLI: transpile', () => {
  const fixture = useTranspileFixture();

  test('--tsconfig-raw applies inline compilerOptions', () => {
    const raw = JSON.stringify({
      compilerOptions: { jsx: 'react-jsx', jsxImportSource: 'preact' },
    });
    const { stdout, exitCode } = runCli([fixture.path('jsx.tsx'), `--tsconfig-raw=${raw}`]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('preact/jsx-runtime');
    expect(stdout).toContain('_jsx');
  });

  test('--tsconfig-raw does not override explicit CLI flags', () => {
    const raw = JSON.stringify({
      compilerOptions: { jsx: 'react-jsx', jsxImportSource: 'preact' },
    });
    const { stdout, exitCode } = runCli([
      fixture.path('jsx.tsx'),
      `--tsconfig-raw=${raw}`,
      '--jsx=classic',
    ]);
    expect(exitCode).toBe(0);
    expect(stdout).not.toContain('preact/jsx-runtime');
    expect(stdout).toContain('React.createElement');
  });

  test('--tsconfig-raw takes precedence over --project file fallback', () => {
    const projectDir = mkdtempSync(join(tmpdir(), 'zntc-cli-tsconfig-raw-'));
    try {
      writeFileSync(
        join(projectDir, 'tsconfig.json'),
        JSON.stringify({ compilerOptions: { jsx: 'react' } }),
      );
      const raw = JSON.stringify({
        compilerOptions: { jsx: 'react-jsx', jsxImportSource: 'preact' },
      });
      const { stdout, exitCode } = runCli([
        fixture.path('jsx.tsx'),
        '--project',
        projectDir,
        `--tsconfig-raw=${raw}`,
      ]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('preact/jsx-runtime');
    } finally {
      rmSync(projectDir, { recursive: true, force: true });
    }
  });

  test('--tsconfig-raw invalid JSON reports a diagnostic', () => {
    const { stderr, exitCode } = runCli([fixture.path('input.ts'), '--tsconfig-raw={']);
    expect(exitCode).toBe(1);
    expect(stderr).toContain('failed to parse --tsconfig-raw');
  });

  test('--tsconfig-raw rejects non-object top-level JSON', () => {
    for (const value of ['null', '[]', '42', '"string"']) {
      const { stderr, exitCode } = runCli([fixture.path('input.ts'), `--tsconfig-raw=${value}`]);
      expect(exitCode).toBe(1);
      expect(stderr).toContain('expected a JSON object');
    }
  });

  test('file-based jsx tsconfig (jsxImportSource=preact) is honored via NAPI', () => {
    // tsconfig 의 jsx/jsxImportSource 가 NAPI(Zig `tsconfig_merge`) 경로로 적용되는지 회귀 가드.
    const projectDir = mkdtempSync(join(tmpdir(), 'zntc-cli-tsconfig-jsx-'));
    try {
      writeFileSync(
        join(projectDir, 'tsconfig.json'),
        JSON.stringify({
          compilerOptions: { jsx: 'react-jsx', jsxImportSource: 'preact' },
        }),
      );
      const { stdout, exitCode } = runCli([fixture.path('jsx.tsx'), '--project', projectDir]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('preact/jsx-runtime');
    } finally {
      rmSync(projectDir, { recursive: true, force: true });
    }
  });
});
