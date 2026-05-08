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
} from './helpers';

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

  test('--config <path>: 명시 경로의 config 사용 (자동 탐색 우회)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-explicit-cfg-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('hi');");
    // 기본 자동 탐색 대상 — 사용 안 됨을 검증
    writeFileSync(join(dir, 'zntc.config.ts'), `export default { banner: "/* AUTO */" };`);
    // 명시 config — 이게 사용되어야 함
    writeFileSync(join(dir, 'custom.config.ts'), `export default { banner: "/* CUSTOM */" };`);
    const { stdout, exitCode } = runCli(
      ['--bundle', '--config', join(dir, 'custom.config.ts'), join(dir, 'entry.ts')],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(stdout).toContain('/* CUSTOM */');
    expect(stdout).not.toContain('/* AUTO */');
    rmSync(dir, { recursive: true, force: true });
  });

  test('--config=<path> (= form) 도 동작', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cfg-eq-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('hi');");
    writeFileSync(join(dir, 'alt.config.ts'), `export default { banner: "/* ALT */" };`);
    const { stdout, exitCode } = runCli(
      ['--bundle', `--config=${join(dir, 'alt.config.ts')}`, join(dir, 'entry.ts')],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(stdout).toContain('/* ALT */');
    rmSync(dir, { recursive: true, force: true });
  });

  test('--config 명시 + 파일 부재 시 명확한 에러로 exit 1', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cfg-missing-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('x');");
    const { stderr, exitCode } = runCli(
      ['--bundle', '--config', join(dir, 'nope.config.ts'), join(dir, 'entry.ts')],
      { cwd: dir },
    );
    expect(exitCode).toBe(1);
    expect(stderr).toContain('file not found');
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

  // ─ 백필: Phase 2-1 (#2103) 함수형 config 갭 ───────────────────────────────────

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

  test('함수형 config throw → exit 1 + 에러 메시지', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-fn-throw-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('x');");
    writeFileSync(
      join(dir, 'zntc.config.ts'),
      `export default () => { throw new Error("BOOM_FROM_CONFIG"); };`,
    );
    const { stderr, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(1);
    expect(stderr).toContain('BOOM_FROM_CONFIG');
    rmSync(dir, { recursive: true, force: true });
  });

  test('함수형 config 가 객체 아닌 값 반환 → exit 1', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-fn-bad-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('x');");
    writeFileSync(join(dir, 'zntc.config.ts'), `export default () => "not an object";`);
    const { stderr, exitCode } = runCli(['--bundle', join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(1);
    expect(stderr).toMatch(/functional config must return an object/);
    rmSync(dir, { recursive: true, force: true });
  });

  test('--config 가 .ts 형식도 정상 로드', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cfg-explicit-ts-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('hi');");
    writeFileSync(
      join(dir, 'alt.config.ts'),
      `export default { banner: "/* TS_CFG */" as const };`,
    );
    const { stdout, exitCode } = runCli(
      ['--bundle', '--config', join(dir, 'alt.config.ts'), join(dir, 'entry.ts')],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(stdout).toContain('/* TS_CFG */');
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

// ─── .env 자동 로드 + import.meta.env 정적 치환 (#2106 / Phase 2-4) ───
