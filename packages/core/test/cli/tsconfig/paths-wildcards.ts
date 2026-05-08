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

describe('CLI: tsconfig paths wildcards', () => {
  test("tsconfig paths: 이중 '*' key 또는 비대칭 wildcard 는 경고 + skip", () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-paths-warn-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'tsconfig.json'),
      JSON.stringify({
        compilerOptions: {
          paths: {
            '@bad/**/y': ['./src/x.ts'],
            '@mix/*': ['./src/plain.ts'],
            '@ok/*': ['./src/*'],
          },
        },
      }),
    );
    writeFileSync(join(dir, 'src', 'hello.ts'), "export const H = 'ok_valid';");
    writeFileSync(join(dir, 'entry.ts'), 'import { H } from "@ok/hello";\nconsole.log(H);');
    const { stdout, stderr, exitCode } = runCli(['--bundle', '-p', dir, join(dir, 'entry.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('ok_valid');
    expect(stderr).toContain('5073');
    expect(stderr).toContain('5063');
    rmSync(dir, { recursive: true, force: true });
  });

  test('tsconfig paths: 중간 wildcard (@pkg/*/types)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-paths-mid-wild-'));
    mkdirSync(join(dir, 'packages/foo/src'), { recursive: true });
    mkdirSync(join(dir, 'packages/bar/src'), { recursive: true });
    writeFileSync(
      join(dir, 'tsconfig.json'),
      JSON.stringify({
        compilerOptions: { paths: { '@pkg/*/types': ['./packages/*/src/types.ts'] } },
      }),
    );
    writeFileSync(join(dir, 'packages/foo/src/types.ts'), "export const T = 'FOO_TYPES';");
    writeFileSync(join(dir, 'packages/bar/src/types.ts'), "export const T = 'BAR_TYPES';");
    writeFileSync(
      join(dir, 'entry.ts'),
      'import { T as F } from "@pkg/foo/types";\nimport { T as B } from "@pkg/bar/types";\nconsole.log(F, B);',
    );
    const { stdout, exitCode } = runCli(['--bundle', '-p', dir, join(dir, 'entry.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('FOO_TYPES');
    expect(stdout).toContain('BAR_TYPES');
    rmSync(dir, { recursive: true, force: true });
  });

  test('tsconfig paths: 다중 후보 순차 fallback (첫 번째 실패 시 두 번째)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-paths-multi-cand-'));
    mkdirSync(join(dir, 'vendor'), { recursive: true });
    writeFileSync(
      join(dir, 'tsconfig.json'),
      JSON.stringify({
        compilerOptions: {
          paths: { '@lib': ['./does-not-exist.ts', './vendor/lib.ts'] },
        },
      }),
    );
    writeFileSync(join(dir, 'vendor/lib.ts'), "export const L = 'FALLBACK_OK';");
    writeFileSync(join(dir, 'entry.ts'), 'import { L } from "@lib";\nconsole.log(L);');
    const { stdout, exitCode } = runCli(['--bundle', '-p', dir, join(dir, 'entry.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('FALLBACK_OK');
    rmSync(dir, { recursive: true, force: true });
  });

  test("tsconfig paths: .js extension 매핑 — '@util' → './src/util.ts'", () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-paths-ext-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'tsconfig.json'),
      JSON.stringify({ compilerOptions: { paths: { '@util': ['./src/util'] } } }),
    );
    writeFileSync(join(dir, 'src', 'util.ts'), "export const U = 'EXT_OK';");
    writeFileSync(join(dir, 'entry.ts'), 'import { U } from "@util";\nconsole.log(U);');
    const { stdout, exitCode } = runCli(['--bundle', '-p', dir, join(dir, 'entry.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('EXT_OK');
    rmSync(dir, { recursive: true, force: true });
  });
});
