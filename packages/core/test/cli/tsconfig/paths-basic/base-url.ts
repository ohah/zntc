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

describe('CLI: tsconfig paths basics > baseUrl behavior', () => {
  test('tsconfig paths: 깊은 서브경로 prefix 매칭 (@/a/b/c)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-paths-deep-'));
    try {
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
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('tsconfig paths: baseUrl 없으면 tsconfig 디렉토리가 기본 base', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-paths-nobase-'));
    try {
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
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
