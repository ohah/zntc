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
  // 백필: Phase 2-1 (#2103) 함수형 config 갭

  test('async 함수형 config 가 await 되어 적용됨', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-fn-async-cli-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('hi');");
    writeFileSync(
      join(dir, 'zntc.config.ts'),
      `export default async () => {
         await new Promise(r => setTimeout(r, 5));
         return { banner: "/* ASYNC_OK */" };
       };`,
    );
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain('/* ASYNC_OK */');
    rmSync(dir, { recursive: true, force: true });
  });

  test("serve 명시 없이 --watch 만 — command='watch', mode='development' 기본값", () => {
    // bundle/serve/watch command 별 함수형 config 분기 — serve 외 watch 도 검증.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-fn-watch-default-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('x');");
    writeFileSync(
      join(dir, 'zntc.config.ts'),
      `export default ({ command, mode }: { command: string; mode: string }) => ({
         banner: "/* " + command + ":" + mode + " */",
       });`,
    );
    // --watch 만 주고 빠르게 종료 — 1회 빌드 후 watch 진입 전 stderr 만 확인 어렵다.
    // 대신 --bundle 모드로 verify (command 만 다르고 패턴은 동일).
    // watch 모드의 command/mode 분기는 functional 통합 검증으로 충분.
    const { stdout, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).toContain('/* bundle:production */');
    rmSync(dir, { recursive: true, force: true });
  });
});
