import {
  describe,
  test,
  expect,
  build,
  buildSync,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from '../helpers';

describe('@zntc/core edge cases: build', () => {
  test('buildSync: 빈 entryPoints 에러', () => {
    expect(() => buildSync({ entryPoints: [] })).toThrow('entryPoints is required');
  });

  test('buildSync: 존재하지 않는 파일', () => {
    const result = buildSync({ entryPoints: ['/nonexistent/file.ts'] });
    expect(result.errors.length).toBeGreaterThan(0);
  });

  test('buildSync: 모든 옵션 동시 사용', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-edge-all-opts-'));
    writeFileSync(join(dir, 'index.ts'), 'export const x = 1;');
    const result = buildSync({
      entryPoints: [join(dir, 'index.ts')],
      format: 'esm',
      platform: 'browser',
      minify: true,
      sourcemap: true,
      metafile: true,
      treeShaking: true,
      keepNames: true,
      charsetUtf8: true,
      banner: '/* banner */',
      footer: '/* footer */',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('/* banner */');
    expect(result.outputFiles[0].text).toContain('/* footer */');
    expect(result.metafile).toBeDefined();
    rmSync(dir, { recursive: true, force: true });
  });

  test('build: 빈 entryPoints 에러', async () => {
    await expect(build({ entryPoints: [] })).rejects.toThrow('entryPoints is required');
  });

  test('build: 존재하지 않는 파일', async () => {
    const result = await build({ entryPoints: ['/nonexistent/file.ts'] });
    expect(result.errors.length).toBeGreaterThan(0);
  });

  test('build: 병렬 호출', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-edge-parallel-'));
    writeFileSync(join(dir, 'a.ts'), 'export const a = 1;');
    writeFileSync(join(dir, 'b.ts'), 'export const b = 2;');

    const [resultA, resultB] = await Promise.all([
      build({ entryPoints: [join(dir, 'a.ts')] }),
      build({ entryPoints: [join(dir, 'b.ts')] }),
    ]);
    expect(resultA.errors.length).toBe(0);
    expect(resultB.errors.length).toBe(0);
    expect(resultA.outputFiles[0].text).toContain('a = 1');
    expect(resultB.outputFiles[0].text).toContain('b = 2');
    rmSync(dir, { recursive: true, force: true });
  });
});
