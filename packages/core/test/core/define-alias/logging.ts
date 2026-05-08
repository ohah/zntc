import {
  describe,
  test,
  expect,
  build,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from './helpers';

describe('@zntc/core define/alias > logging', () => {
  test("logLevel='silent': errors 도 빈 배열 (build 객체로만 결과 확인)", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-loglevel-silent-'));
    writeFileSync(
      join(dir, 'index.ts'),
      'import * as r from "unresolved-pkg-zzz";\nconsole.log(r);',
    );

    const baseline = await build({ entryPoints: [join(dir, 'index.ts')] });
    expect(baseline.errors.length).toBeGreaterThan(0);

    const silent = await build({
      entryPoints: [join(dir, 'index.ts')],
      logLevel: 'silent',
    });
    expect(silent.errors).toEqual([]);
    expect(silent.warnings).toEqual([]);
    rmSync(dir, { recursive: true, force: true });
  });

  test("logLevel='warning' (default): errors 그대로 보존", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-loglevel-warning-'));
    writeFileSync(
      join(dir, 'index.ts'),
      'import * as r from "unresolved-pkg-yyy";\nconsole.log(r);',
    );

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      logLevel: 'warning',
    });
    expect(result.errors.length).toBeGreaterThan(0);
    rmSync(dir, { recursive: true, force: true });
  });

  test('logLimit=1: errors 가 여러 개여도 1개로 truncate', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-loglimit-'));
    writeFileSync(
      join(dir, 'index.ts'),
      [
        'import * as a from "unresolved-pkg-aaa";',
        'import * as b from "unresolved-pkg-bbb";',
        'import * as c from "unresolved-pkg-ccc";',
        'console.log(a, b, c);',
      ].join('\n'),
    );

    const baseline = await build({ entryPoints: [join(dir, 'index.ts')] });
    expect(baseline.errors.length).toBeGreaterThan(1);

    const limited = await build({
      entryPoints: [join(dir, 'index.ts')],
      logLimit: 1,
    });
    expect(limited.errors.length).toBe(1);
    rmSync(dir, { recursive: true, force: true });
  });
});
