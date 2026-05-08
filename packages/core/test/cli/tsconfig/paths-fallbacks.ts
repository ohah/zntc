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

describe('CLI: tsconfig paths fallbacks', () => {
  test('tsconfig paths: 배열 여러 후보 중 첫 번째만 사용 (v1 제약)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-paths-multi-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'tsconfig.json'),
      JSON.stringify({
        compilerOptions: { paths: { '@m': ['./src/a.ts', './src/b.ts'] } },
      }),
    );
    writeFileSync(join(dir, 'src', 'a.ts'), "export const M = 'FIRST';");
    writeFileSync(join(dir, 'src', 'b.ts'), "export const M = 'SECOND';");
    writeFileSync(join(dir, 'entry.ts'), 'import { M } from "@m";\nconsole.log(M);');
    const { stdout, exitCode } = runCli(['--bundle', '-p', dir, join(dir, 'entry.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('FIRST');
    expect(stdout).not.toContain('SECOND');
    rmSync(dir, { recursive: true, force: true });
  });

  test('tsconfig paths: 빈 paths 객체는 무시 (no crash)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-paths-empty-'));
    writeFileSync(join(dir, 'tsconfig.json'), JSON.stringify({ compilerOptions: { paths: {} } }));
    writeFileSync(join(dir, 'entry.ts'), "console.log('OK');");
    const { stdout, exitCode } = runCli(['--bundle', '-p', dir, join(dir, 'entry.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('OK');
    rmSync(dir, { recursive: true, force: true });
  });

  test('tsconfig paths: extends 체인에서 paths 상속', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-paths-extends-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'tsconfig.base.json'),
      JSON.stringify({ compilerOptions: { paths: { '@base': ['./src/base.ts'] } } }),
    );
    writeFileSync(join(dir, 'tsconfig.json'), JSON.stringify({ extends: './tsconfig.base.json' }));
    writeFileSync(join(dir, 'src', 'base.ts'), "export const B = 'EXTENDED';");
    writeFileSync(join(dir, 'entry.ts'), 'import { B } from "@base";\nconsole.log(B);');
    const { stdout, exitCode } = runCli(['--bundle', '-p', dir, join(dir, 'entry.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('EXTENDED');
    rmSync(dir, { recursive: true, force: true });
  });

  test('tsconfig paths: 존재하지 않는 tsconfig 경로 → silent fallback (no crash)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-paths-missing-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('OK');");
    const { stdout, exitCode } = runCli([
      '--bundle',
      '-p',
      '/nonexistent/path/tsconfig.json',
      join(dir, 'entry.ts'),
    ]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('OK');
    rmSync(dir, { recursive: true, force: true });
  });

  test('tsconfig paths: 자동 발견 — entry 상위 디렉토리에서 tsconfig.json 탐색', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-auto-discover-'));
    mkdirSync(join(dir, 'src', 'deep'), { recursive: true });
    writeFileSync(
      join(dir, 'tsconfig.json'),
      JSON.stringify({ compilerOptions: { baseUrl: '.', paths: { '@/*': ['./src/*'] } } }),
    );
    writeFileSync(join(dir, 'src', 'utils.ts'), "export function hello() { return 'AUTO_OK'; }");
    writeFileSync(
      join(dir, 'src', 'deep', 'entry.ts'),
      'import { hello } from "@/utils";\nconsole.log(hello());',
    );
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'src', 'deep', 'entry.ts')]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain('AUTO_OK');
    rmSync(dir, { recursive: true, force: true });
  });
});
