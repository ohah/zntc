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

describe('CLI: arg parsing > env and externals', () => {
  test('--jsx=automatic + --external react', () => {
    const jsxDir = mkdtempSync(join(tmpdir(), 'zntc-cli-jsx-'));
    try {
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
    } finally {
      rmSync(jsxDir, { recursive: true, force: true });
    }
  });

  test('--define:KEY=VALUE', () => {
    const defDir = mkdtempSync(join(tmpdir(), 'zntc-cli-define-'));
    try {
      writeFileSync(join(defDir, 'input.ts'), 'console.log(process.env.NODE_ENV);');
      const { stdout, exitCode } = runCli([
        '--bundle',
        join(defDir, 'input.ts'),
        '--define:process.env.NODE_ENV="production"',
      ]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('"production"');
      expect(stdout).not.toContain('process.env.NODE_ENV');
    } finally {
      rmSync(defDir, { recursive: true, force: true });
    }
  });

  test('browser bundle defaults process.env.NODE_ENV to production', () => {
    const defDir = mkdtempSync(join(tmpdir(), 'zntc-cli-node-env-'));
    try {
      writeFileSync(join(defDir, 'input.ts'), 'console.log(process.env.NODE_ENV);');
      const { stdout, exitCode } = runCli(['--bundle', join(defDir, 'input.ts')]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('"production"');
      expect(stdout).not.toContain('process.env.NODE_ENV');
    } finally {
      rmSync(defDir, { recursive: true, force: true });
    }
  });

  test('여러 --external 반복', () => {
    const extDir = mkdtempSync(join(tmpdir(), 'zntc-cli-multi-ext-'));
    try {
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
    } finally {
      rmSync(extDir, { recursive: true, force: true });
    }
  });
});
