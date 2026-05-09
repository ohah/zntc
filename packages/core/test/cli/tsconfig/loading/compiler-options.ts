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
} from '../../helpers';

describe('CLI: tsconfig loading > compiler options', () => {
  test('tsconfig.json에서 experimentalDecorators 자동 로드', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-tsconfig-'));
    try {
      writeFileSync(
        join(dir, 'tsconfig.json'),
        JSON.stringify({ compilerOptions: { experimentalDecorators: true } }),
      );
      writeFileSync(
        join(dir, 'input.ts'),
        '@sealed\nclass Greeter {\n  greeting: string;\n  constructor(message: string) { this.greeting = message; }\n}',
      );

      const { stdout, exitCode } = runCli([join(dir, 'input.ts')]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('__decorate');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('tsconfig.json에서 jsx 자동 로드', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-tsconfig-jsx-'));
    try {
      writeFileSync(
        join(dir, 'tsconfig.json'),
        JSON.stringify({ compilerOptions: { jsx: 'react-jsx' } }),
      );
      writeFileSync(join(dir, 'app.tsx'), 'export default () => <div>hello</div>;');

      const { stdout, exitCode } = runCli([join(dir, 'app.tsx')]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('jsx');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
