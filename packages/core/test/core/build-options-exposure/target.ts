import { describe, test, expect, buildSync, join, useBuildOptionsFixture } from './helpers';

describe('BuildOptions: 누락 옵션 노출 (#1005) > target', () => {
  const getDir = useBuildOptionsFixture();

  test('target: es5 → arrow function이 function으로 변환됨', () => {
    const dir = getDir();
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      target: 'es5',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('=>');
    expect(result.outputFiles[0].text).toContain('function');
  });

  test('target: esnext → arrow function 유지', () => {
    const dir = getDir();
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      target: 'esnext',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('=>');
  });
});
