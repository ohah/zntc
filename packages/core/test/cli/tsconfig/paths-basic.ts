import {
  describe,
  test,
  expect,
  mkdtempSync,
  writeFileSync,
  rmSync,
  mkdirSync,
  tmpdir,
  join,
  runCli,
} from '../helpers';

describe('CLI: tsconfig paths basics', () => {
  test('tsconfig paths: wildcard + exact alias 가 bundler 에서 해석됨', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-tsc-paths-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'tsconfig.json'),
      JSON.stringify({
        compilerOptions: {
          baseUrl: '.',
          paths: {
            '@/*': ['./src/*'],
            '@utils': ['./src/utils.ts'],
          },
        },
      }),
    );
    writeFileSync(
      join(dir, 'src', 'utils.ts'),
      'export function hello(name: string): string { return `Hello, ${name}!`; }',
    );
    writeFileSync(join(dir, 'src', 'greet.ts'), "export function greet(): string { return 'hi'; }");
    writeFileSync(
      join(dir, 'entry.ts'),
      'import { hello } from "@utils";\nimport { greet } from "@/greet";\nconsole.log(hello("world"), greet());',
    );
    const { stdout, exitCode } = runCli(['--bundle', '-p', dir, join(dir, 'entry.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('Hello, ${name}!');
    expect(stdout).toContain(`return "hi"`);
    rmSync(dir, { recursive: true, force: true });
  });

  test('--alias 가 tsconfig paths 를 덮어씀', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-alias-priority-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    mkdirSync(join(dir, 'alt'), { recursive: true });
    writeFileSync(
      join(dir, 'tsconfig.json'),
      JSON.stringify({
        compilerOptions: { paths: { '@utils': ['./src/utils.ts'] } },
      }),
    );
    writeFileSync(
      join(dir, 'src', 'utils.ts'),
      "export function hello(): string { return 'FROM_TSCONFIG'; }",
    );
    writeFileSync(
      join(dir, 'alt', 'utils.ts'),
      "export function hello(): string { return 'FROM_ALIAS_CLI'; }",
    );
    writeFileSync(join(dir, 'entry.ts'), 'import { hello } from "@utils";\nconsole.log(hello());');

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

    rmSync(dir, { recursive: true, force: true });
  });

  test('tsconfig paths: 깊은 서브경로 prefix 매칭 (@/a/b/c)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-paths-deep-'));
    mkdirSync(join(dir, 'src', 'a', 'b'), { recursive: true });
    writeFileSync(
      join(dir, 'tsconfig.json'),
      JSON.stringify({ compilerOptions: { baseUrl: '.', paths: { '@/*': ['./src/*'] } } }),
    );
    writeFileSync(join(dir, 'src', 'a', 'b', 'c.ts'), "export const V = 'DEEP_OK';");
    writeFileSync(join(dir, 'entry.ts'), 'import { V } from "@/a/b/c";\nconsole.log(V);');
    const { stdout, exitCode } = runCli(['--bundle', '-p', dir, join(dir, 'entry.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('DEEP_OK');
    rmSync(dir, { recursive: true, force: true });
  });

  test('tsconfig paths: baseUrl 없으면 tsconfig 디렉토리가 기본 base', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-paths-nobase-'));
    mkdirSync(join(dir, 'lib'), { recursive: true });
    writeFileSync(
      join(dir, 'tsconfig.json'),
      JSON.stringify({ compilerOptions: { paths: { '#lib': ['./lib/index.ts'] } } }),
    );
    writeFileSync(join(dir, 'lib', 'index.ts'), "export const L = 'NOBASE_OK';");
    writeFileSync(join(dir, 'entry.ts'), 'import { L } from "#lib";\nconsole.log(L);');
    const { stdout, exitCode } = runCli(['--bundle', '-p', dir, join(dir, 'entry.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('NOBASE_OK');
    rmSync(dir, { recursive: true, force: true });
  });
});
