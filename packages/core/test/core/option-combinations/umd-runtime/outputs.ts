import {
  build,
  createOptionCombinationFixture,
  describe,
  expect,
  join,
  removeOptionCombinationFixture,
  test,
  writeFileSync,
} from '../helpers';

describe('옵션 조합 통합 테스트 - UMD runtime outputs', () => {
  test('format: umd + minify → 압축 후 런타임 실행', async () => {
    const dir = createOptionCombinationFixture();
    try {
      const result = await build({
        entryPoints: [join(dir, 'lib.ts')],
        format: 'umd',
        globalName: 'M',
        minify: true,
      });
      expect(result.errors.length).toBe(0);
      const mod: any = { exports: {} };
      new Function('module', 'exports', result.outputFiles[0].text)(mod, mod.exports);
      expect(mod.exports.util()).toBe(42);
    } finally {
      removeOptionCombinationFixture(dir);
    }
  });

  test('format: umd + 다중 export → 모든 export 접근 가능', async () => {
    const dir = createOptionCombinationFixture();
    try {
      writeFileSync(
        join(dir, 'multi.ts'),
        'export const a = 1;\nexport const b = 2;\nexport function sum() { return a + b; }',
      );
      const result = await build({
        entryPoints: [join(dir, 'multi.ts')],
        format: 'umd',
        globalName: 'Multi',
      });
      expect(result.errors.length).toBe(0);
      const mod: any = { exports: {} };
      new Function('module', 'exports', result.outputFiles[0].text)(mod, mod.exports);
      expect(mod.exports.a).toBe(1);
      expect(mod.exports.b).toBe(2);
      expect(mod.exports.sum()).toBe(3);
    } finally {
      removeOptionCombinationFixture(dir);
    }
  });

  test('format: umd + sourcemap → 소스맵 생성', async () => {
    const dir = createOptionCombinationFixture();
    try {
      const result = await build({
        entryPoints: [join(dir, 'lib.ts')],
        format: 'umd',
        globalName: 'Lib',
        sourcemap: true,
      });
      expect(result.errors.length).toBe(0);
      const mapFile = result.outputFiles.find((f: any) => f.path.endsWith('.map'));
      expect(mapFile).toBeDefined();
      expect(mapFile!.text).toContain('mappings');
    } finally {
      removeOptionCombinationFixture(dir);
    }
  });

  test('format: umd + external → 외부 모듈 제외', async () => {
    const dir = createOptionCombinationFixture();
    try {
      writeFileSync(join(dir, 'ext.ts'), 'import React from "react";\nexport default React;');
      const result = await build({
        entryPoints: [join(dir, 'ext.ts')],
        format: 'umd',
        globalName: 'App',
        external: ['react'],
      });
      expect(result.errors.length).toBe(0);
      expect(result.outputFiles[0].text).toContain('require');
    } finally {
      removeOptionCombinationFixture(dir);
    }
  });
});
