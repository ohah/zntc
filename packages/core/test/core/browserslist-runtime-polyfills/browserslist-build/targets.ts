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
} from '../helpers';

describe('@zntc/core browserslist > build API', () => {
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

  test('browserslist: build API — target + browserslist 동시 지정 시 browserslist 우선', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bs-both-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      'export async function run() { return await Promise.resolve(1); }',
    );
    // target=es5(모두 다운레벨)인데 browserslist=modern(esnext) → 변환 안 해야 함
    const r = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      target: 'es5',
      browserslist: 'chrome 100',
    });
    expect(r.outputFiles[0].text).not.toContain('__async');
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
