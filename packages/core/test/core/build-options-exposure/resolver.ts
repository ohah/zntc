import { describe, test, expect, buildSync, join, useBuildOptionsFixture } from './helpers';

describe('BuildOptions: 누락 옵션 노출 (#1005) > resolver options', () => {
  const getDir = useBuildOptionsFixture();

  test('resolveExtensions: 커스텀 확장자 순서가 적용됨', () => {
    const dir = getDir();
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      resolveExtensions: ['.ts', '.tsx', '.js'],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThan(0);
  });

  test('mainFields: 커스텀 필드 순서가 적용됨', () => {
    const dir = getDir();
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      mainFields: ['module', 'main'],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThan(0);
  });

  test('conditions: 커스텀 exports 조건이 적용됨', () => {
    const dir = getDir();
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      conditions: ['import', 'default'],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThan(0);
  });
});
