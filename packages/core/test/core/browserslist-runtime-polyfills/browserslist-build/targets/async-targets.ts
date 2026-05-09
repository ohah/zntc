import {
  buildSync,
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  writeFileSync,
} from '../../helpers';

describe('@zntc/core browserslist > build API > async targets', () => {
  test('browserslist: build API도 해석 (BuildOptions.browserslist)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bs-build-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      'export async function run() { return await Promise.resolve(1); }',
    );
    // 오래된 쿼리 → async 다운레벨
    const r = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      browserslist: 'chrome 50',
    });
    const code = r.outputFiles[0].text;
    expect(code).toContain('__async');
    rmSync(dir, { recursive: true });
  });

  test('browserslist: build API — 모던 타겟은 async 유지', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bs-build2-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      'export async function run() { return await Promise.resolve(1); }',
    );
    const r = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      browserslist: 'last 2 chrome versions',
    });
    const code = r.outputFiles[0].text;
    expect(code).toContain('async function');
    expect(code).not.toContain('__async');
    rmSync(dir, { recursive: true });
  });
});
