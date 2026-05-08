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

describe('CLI: 함수형 config + --config flag', () => {
  test('함수형 config: 자동 탐색 + bundle 기본 mode', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-fn-cfg-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('FN_CFG');");
    writeFileSync(
      join(dir, 'zntc.config.ts'),
      `export default ({ command, mode }: { command: string; mode: string }) => ({
         banner: "/* " + command + ":" + mode + " */",
       });`,
    );
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain('/* bundle:production */');
    expect(stdout).toContain('FN_CFG');
    rmSync(dir, { recursive: true, force: true });
  });

  test('함수형 config: --mode 명시값 전달', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-fn-mode-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('x');");
    writeFileSync(
      join(dir, 'zntc.config.ts'),
      `export default ({ mode }: { mode: string }) => ({
         banner: "/* mode=" + mode + " */",
       });`,
    );
    const { stdout, exitCode } = runCli(['--bundle', '--mode=staging', join(dir, 'entry.ts')], {
      cwd: dir,
    });
    expect(exitCode).toBe(0);
    expect(stdout).toContain('/* mode=staging */');
    rmSync(dir, { recursive: true, force: true });
  });

  test('함수형 config + 객체 머지: BuildOptions 가 정상 적용됨', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-fn-merge-'));
    writeFileSync(join(dir, 'src.ts'), "export const X = 'FN_ENTRY';");
    writeFileSync(
      join(dir, 'zntc.config.ts'),
      `export default () => ({
         entryPoints: ["${join(dir, 'src.ts').replace(/\\/g, '/')}"],
         minify: true,
       });`,
    );
    const { stdout, exitCode } = runCli(['--bundle'], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain('FN_ENTRY');
    rmSync(dir, { recursive: true, force: true });
  });
});
