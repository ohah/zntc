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

describe('CLI: tsconfig loading > project paths', () => {
  test('--project로 명시적 tsconfig 경로', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-project-'));
    const configDir = mkdtempSync(join(tmpdir(), 'zntc-cli-config-'));
    try {
      writeFileSync(
        join(configDir, 'tsconfig.json'),
        JSON.stringify({ compilerOptions: { experimentalDecorators: true } }),
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
    } finally {
      rmSync(dir, { recursive: true, force: true });
      rmSync(configDir, { recursive: true, force: true });
    }
  });

  test('--tsconfig-path 는 -p 의 alias (NAPI `tsconfigPath` 와 통일된 이름)', () => {
    const configDir = mkdtempSync(join(tmpdir(), 'zntc-cli-tsc-alias-'));
    try {
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
    } finally {
      rmSync(configDir, { recursive: true, force: true });
    }
  });
});
