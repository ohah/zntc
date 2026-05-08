import {
  describe,
  test,
  expect,
  buildSync,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from './helpers';

describe('profile options (PR 2 — entry point integration)', () => {
  test('BundleOptions.profile 을 받아들인다 (no throw)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-profile-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');
    const r = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      profile: ['all'],
    });
    expect(r.outputFiles[0].text).toContain('const x = 1');
    rmSync(dir, { recursive: true });
  });

  test('BundleOptions.profileLevel 을 받아들인다 (no throw)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-profile-lvl-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');
    const r = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      profile: ['parse', 'transform'],
      profileLevel: 'detailed',
    });
    expect(r.outputFiles[0].text).toContain('const x = 1');
    rmSync(dir, { recursive: true });
  });

  test('BundleOptions.profileFormat 은 타입에 존재 (향후 결과 노출용)', () => {
    // PR 10 에서 build/buildSync 결과에 profile report 를 실제 포함시킬 예정.
    // PR 2 는 옵션 파싱만 검증.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-profile-fmt-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');
    const r = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      profile: ['all'],
      profileFormat: 'json',
    });
    expect(r.outputFiles[0].text).toContain('const x = 1');
    rmSync(dir, { recursive: true });
  });

  test('잘못된 profileLevel 은 무시 (graceful degrade)', () => {
    // Level.fromString 이 null 반환 → profile 모듈이 level 변경 안 함. build 는 성공.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-profile-bad-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');
    const r = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      profile: ['all'],
      // @ts-expect-error — runtime 허용성 검증
      profileLevel: 'bogus',
    });
    expect(r.outputFiles[0].text).toContain('const x = 1');
    rmSync(dir, { recursive: true });
  });

  test('profile 미지정 시 빌드는 정상 동작 (default: 비활성)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-noprofile-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');
    const r = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
    });
    expect(r.outputFiles[0].text).toContain('const x = 1');
    rmSync(dir, { recursive: true });
  });
});
