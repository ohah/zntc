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

describe('CLI: tsconfig loading', () => {
  test('tsconfig.json에서 experimentalDecorators 자동 로드', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-tsconfig-'));
    writeFileSync(
      join(dir, 'tsconfig.json'),
      JSON.stringify({
        compilerOptions: { experimentalDecorators: true },
      }),
    );
    writeFileSync(
      join(dir, 'input.ts'),
      '@sealed\nclass Greeter {\n  greeting: string;\n  constructor(message: string) { this.greeting = message; }\n}',
    );

    const { stdout, exitCode } = runCli([join(dir, 'input.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('__decorate');
    rmSync(dir, { recursive: true, force: true });
  });

  test('tsconfig.json에서 jsx 자동 로드', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-tsconfig-jsx-'));
    writeFileSync(
      join(dir, 'tsconfig.json'),
      JSON.stringify({
        compilerOptions: { jsx: 'react-jsx' },
      }),
    );
    writeFileSync(join(dir, 'app.tsx'), 'export default () => <div>hello</div>;');

    const { stdout, exitCode } = runCli([join(dir, 'app.tsx')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('jsx');
    rmSync(dir, { recursive: true, force: true });
  });

  test('--project로 명시적 tsconfig 경로', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-project-'));
    const configDir = mkdtempSync(join(tmpdir(), 'zntc-cli-config-'));
    writeFileSync(
      join(configDir, 'tsconfig.json'),
      JSON.stringify({
        compilerOptions: { experimentalDecorators: true },
      }),
    );
    writeFileSync(
      join(dir, 'input.ts'),
      '@sealed\nclass Greeter { greeting: string; constructor(m: string) { this.greeting = m; } }',
    );

    const { stdout, exitCode } = runCli([
      join(dir, 'input.ts'),
      '-p',
      join(configDir, 'tsconfig.json'),
    ]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('__decorate');
    rmSync(dir, { recursive: true, force: true });
    rmSync(configDir, { recursive: true, force: true });
  });

  test('--tsconfig-path 는 -p 의 alias (NAPI `tsconfigPath` 와 통일된 이름)', () => {
    const configDir = mkdtempSync(join(tmpdir(), 'zntc-cli-tsc-alias-'));
    writeFileSync(
      join(configDir, 'tsconfig.json'),
      JSON.stringify({ compilerOptions: { verbatimModuleSyntax: true } }),
    );
    const inputPath = join(configDir, 'input.ts');
    writeFileSync(inputPath, 'import { foo } from "./bar";');

    for (const args of [
      ['--tsconfig-path', configDir],
      [`--tsconfig-path=${configDir}`],
      ['--tsconfig-path', join(configDir, 'tsconfig.json')],
      ['-p', join(configDir, 'tsconfig.json')],
    ]) {
      const { stdout, exitCode } = runCli([inputPath, ...args]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('./bar');
    }
    rmSync(configDir, { recursive: true, force: true });
  });

  test('CLI 옵션이 tsconfig보다 우선', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-override-'));
    writeFileSync(
      join(dir, 'tsconfig.json'),
      JSON.stringify({
        compilerOptions: { jsx: 'react' },
      }),
    );
    writeFileSync(join(dir, 'app.tsx'), 'export default () => <div>hello</div>;');

    const { stdout, exitCode } = runCli([join(dir, 'app.tsx'), '--jsx=automatic']);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('jsx');
    rmSync(dir, { recursive: true, force: true });
  });
});
