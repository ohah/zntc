import {
  describe,
  test,
  expect,
  runCli,
  existsSync,
  join,
  mkdtempSync,
  rmSync,
  tmpdir,
  writeFileSync,
} from '../helpers';

describe('CLI: bundle errors', () => {
  test('존재하지 않는 entry → 에러', () => {
    const { exitCode } = runCli(['--bundle', '/nonexistent/entry.ts']);
    expect(exitCode).toBe(1);
  });
});

/**
 * 산출물 방출 게이트 — stdout / `--outfile` / `--outdir` 세 표면이 **같은 정책**이어야 한다.
 *
 * 정책: 번들 자체가 앞뒤가 안 맞는 에러(`missing_export` / `ambiguous_export`)면 산출물을
 * 내지 않는다. 해석 불가 import 는 external 로 남기고 **산출물은 낸다**. exit code 는 이와
 * 별개로 에러가 하나라도 있으면 1.
 *
 * (Zig 초보자 설명) 과거엔 네이티브 쪽 기본값이 `write: true` 라 `--outfile` 만 게이트를
 * 우회해 파일이 먼저 디스크에 떨어졌다. 지금은 `runBundle` 이 `write: false` 를 강제해
 * **디스크 기록 주체를 JS 한 곳**으로 모은다.
 */
describe('CLI: bundle 산출물 방출 게이트', () => {
  function withFixture(files: Record<string, string>, run: (dir: string) => void) {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-gate-'));
    try {
      for (const [name, content] of Object.entries(files)) {
        writeFileSync(join(dir, name), content);
      }
      run(dir);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }

  const MISSING_EXPORT = {
    'dep.ts': 'export const b = 1;\n',
    'entry.ts': 'import { nope } from "./dep";\nconsole.log(nope);\n',
  };

  const AMBIGUOUS_EXPORT = {
    'a.ts': 'export const dup = 1;\n',
    'b.ts': 'export const dup = 2;\n',
    'barrel.ts': 'export * from "./a";\nexport * from "./b";\n',
    'entry.ts': 'import { dup } from "./barrel";\nconsole.log(dup);\n',
  };

  const UNRESOLVED_IMPORT = {
    'entry.ts': 'import { x } from "./ghost";\nconsole.log(x);\n',
  };

  test('missing export — stdout 도 --outfile 도 산출물을 내지 않는다', () => {
    withFixture(MISSING_EXPORT, (dir) => {
      const stdout = runCli(['--bundle', 'entry.ts'], { cwd: dir });
      expect(stdout.exitCode).toBe(1);
      expect(stdout.stdout.trim()).toBe('');

      const outPath = join(dir, 'o.js');
      const outfile = runCli(['--bundle', 'entry.ts', '--outfile', 'o.js'], { cwd: dir });
      expect(outfile.exitCode).toBe(1);
      expect(existsSync(outPath)).toBe(false);
    });
  });

  test('ambiguous export — stdout 도 --outfile 도 산출물을 내지 않는다', () => {
    withFixture(AMBIGUOUS_EXPORT, (dir) => {
      const stdout = runCli(['--bundle', 'entry.ts'], { cwd: dir });
      expect(stdout.exitCode).toBe(1);
      expect(stdout.stdout.trim()).toBe('');

      const outPath = join(dir, 'o.js');
      const outfile = runCli(['--bundle', 'entry.ts', '--outfile', 'o.js'], { cwd: dir });
      expect(outfile.exitCode).toBe(1);
      expect(existsSync(outPath)).toBe(false);
    });
  });

  test('missing export — --outdir 도 산출물을 내지 않는다', () => {
    withFixture(MISSING_EXPORT, (dir) => {
      const res = runCli(['--bundle', 'entry.ts', '--outdir', 'out'], { cwd: dir });
      expect(res.exitCode).toBe(1);
      expect(existsSync(join(dir, 'out', 'entry.js'))).toBe(false);
      expect(existsSync(join(dir, 'out', 'bundle.js'))).toBe(false);
    });
  });

  test('해석 불가 import — exit 1 이지만 산출물은 낸다 (stdout / --outfile 일치)', () => {
    withFixture(UNRESOLVED_IMPORT, (dir) => {
      const stdout = runCli(['--bundle', 'entry.ts'], { cwd: dir });
      expect(stdout.exitCode).toBe(1);
      expect(stdout.stdout.length).toBeGreaterThan(0);

      const outPath = join(dir, 'o.js');
      const outfile = runCli(['--bundle', 'entry.ts', '--outfile', 'o.js'], { cwd: dir });
      expect(outfile.exitCode).toBe(1);
      expect(existsSync(outPath)).toBe(true);
    });
  });

  test('정상 빌드 — 세 표면 모두 산출물 + exit 0', () => {
    withFixture(
      {
        'dep.ts': 'export const b = 1;\n',
        'entry.ts': 'import { b } from "./dep";\nconsole.log(b);\n',
      },
      (dir) => {
        const stdout = runCli(['--bundle', 'entry.ts'], { cwd: dir });
        expect(stdout.exitCode).toBe(0);
        expect(stdout.stdout).toContain('console.log');

        const outfile = runCli(['--bundle', 'entry.ts', '--outfile', 'o.js'], { cwd: dir });
        expect(outfile.exitCode).toBe(0);
        expect(existsSync(join(dir, 'o.js'))).toBe(true);

        const outdir = runCli(['--bundle', 'entry.ts', '--outdir', 'out'], { cwd: dir });
        expect(outdir.exitCode).toBe(0);
        expect(existsSync(join(dir, 'out', 'bundle.js'))).toBe(true);
      },
    );
  });
});
