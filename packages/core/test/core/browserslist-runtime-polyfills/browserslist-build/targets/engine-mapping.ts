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

describe('@zntc/core browserslist > build API > engine mapping', () => {
  test('browserslist: build API — 여러 엔진 union 중 가장 오래된 기준 (보수적)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bs-union-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      // optional chaining 사용
      'export const x = (o: any) => o?.a?.b;',
    );
    // chrome 100 (지원) + safari 12 (미지원) → safari 12 기준 다운레벨
    const r = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      browserslist: ['chrome 100', 'safari 12'],
    });
    expect(r.outputFiles[0].text).not.toContain('?.');
    rmSync(dir, { recursive: true });
  });

  test('browserslist: build API — 매핑 불가능한 엔진만 있으면 esnext', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bs-unknown-'));
    writeFileSync(join(dir, 'entry.ts'), 'export async function run() { return 1; }');
    const r = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      browserslist: 'samsung 20',
    });
    expect(r.outputFiles[0].text).toContain('async function');
    rmSync(dir, { recursive: true });
  });

  test('browserslist: build API — 빈 배열 입력 시 기본 (보수적 esnext)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bs-empty-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');
    // 빈 배열 → browserslist가 default 쿼리로 처리하므로 에러 없어야 함
    expect(() =>
      buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        browserslist: [] as string[],
      }),
    ).not.toThrow();
    rmSync(dir, { recursive: true });
  });

  test('browserslist: build API — ios_saf 버전 매핑 (RN 시나리오)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bs-ios-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      // ES2020 optional_chaining — ios 13 미만 미지원
      'export const x = (o: any) => o?.a;',
    );
    const r = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      browserslist: 'ios_saf 12',
    });
    expect(r.outputFiles[0].text).not.toContain('?.');
    rmSync(dir, { recursive: true });
  });
});
