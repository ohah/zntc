import {
  describe,
  expect,
  join,
  mkdirSync,
  mkdtempSync,
  rmSync,
  runCli,
  test,
  tmpdir,
  writeFileSync,
} from '../../helpers';

describe('CLI: tsconfig paths basics > wildcard and alias', () => {
  test('tsconfig paths: wildcard + exact alias 가 bundler 에서 해석됨', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-tsc-paths-'));
    try {
      mkdirSync(join(dir, 'src'), { recursive: true });
      writeFileSync(
        join(dir, 'tsconfig.json'),
        JSON.stringify({
          compilerOptions: {
            baseUrl: '.',
            paths: { '@/*': ['./src/*'], '@utils': ['./src/utils.ts'] },
          },
        }),
      );
      writeFileSync(
        join(dir, 'src', 'utils.ts'),
        'export function hello(name: string): string { return `Hello, ${name}!`; }',
      );
      writeFileSync(
        join(dir, 'src', 'greet.ts'),
        "export function greet(): string { return 'hi'; }",
      );
      writeFileSync(
        join(dir, 'entry.ts'),
        'import { hello } from "@utils";\nimport { greet } from "@/greet";\nconsole.log(hello("world"), greet());',
      );
      const { stdout, exitCode } = runCli(['--bundle', '-p', dir, join(dir, 'entry.ts')]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('Hello, ${name}!');
      expect(stdout).toContain(`return "hi"`);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('--alias 가 tsconfig paths 를 덮어씀', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-alias-priority-'));
    try {
      mkdirSync(join(dir, 'src'), { recursive: true });
      mkdirSync(join(dir, 'alt'), { recursive: true });
      writeFileSync(
        join(dir, 'tsconfig.json'),
        JSON.stringify({ compilerOptions: { paths: { '@utils': ['./src/utils.ts'] } } }),
      );
      writeFileSync(
        join(dir, 'src', 'utils.ts'),
        "export function hello(): string { return 'FROM_TSCONFIG'; }",
      );
      writeFileSync(
        join(dir, 'alt', 'utils.ts'),
        "export function hello(): string { return 'FROM_ALIAS_CLI'; }",
      );
      writeFileSync(
        join(dir, 'entry.ts'),
        'import { hello } from "@utils";\nconsole.log(hello());',
      );

      const withoutAlias = runCli(['--bundle', '-p', dir, join(dir, 'entry.ts')]);
      expect(withoutAlias.exitCode).toBe(0);
      expect(withoutAlias.stdout).toContain('FROM_TSCONFIG');

      const withAlias = runCli([
        '--bundle',
        '-p',
        dir,
        `--alias:@utils=${join(dir, 'alt', 'utils.ts')}`,
        join(dir, 'entry.ts'),
      ]);
      expect(withAlias.exitCode).toBe(0);
      expect(withAlias.stdout).toContain('FROM_ALIAS_CLI');
      expect(withAlias.stdout).not.toContain('FROM_TSCONFIG');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
