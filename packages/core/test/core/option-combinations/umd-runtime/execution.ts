import {
  build,
  createOptionCombinationFixture,
  describe,
  expect,
  join,
  removeOptionCombinationFixture,
  test,
} from '../helpers';

describe('옵션 조합 통합 테스트 - UMD runtime execution', () => {
  test('format: umd + globalName → 글로벌 변수로 실행 가능', async () => {
    const dir = createOptionCombinationFixture();
    try {
      const result = await build({
        entryPoints: [join(dir, 'lib.ts')],
        format: 'umd',
        globalName: 'MyLib',
      });
      expect(result.errors.length).toBe(0);
      const text = result.outputFiles[0].text;
      expect(text).toContain('typeof define === "function"');
      expect(text).toContain('root.MyLib = factory()');
      const ctx: Record<string, any> = { self: {} };
      new Function('self', text)(ctx.self);
      expect((ctx.self as any).MyLib).toBeDefined();
      expect((ctx.self as any).MyLib.util()).toBe(42);
    } finally {
      removeOptionCombinationFixture(dir);
    }
  });

  test('format: umd → CJS 모드로 실행 가능', async () => {
    const dir = createOptionCombinationFixture();
    try {
      const result = await build({
        entryPoints: [join(dir, 'lib.ts')],
        format: 'umd',
        globalName: 'MyLib',
      });
      const mod: any = { exports: {} };
      new Function('module', 'exports', result.outputFiles[0].text)(mod, mod.exports);
      expect(mod.exports.util()).toBe(42);
    } finally {
      removeOptionCombinationFixture(dir);
    }
  });

  test('format: umd (globalName 없음) → factory 직접 실행', async () => {
    const dir = createOptionCombinationFixture();
    try {
      const result = await build({
        entryPoints: [join(dir, 'lib.ts')],
        format: 'umd',
      });
      expect(result.errors.length).toBe(0);
      expect(result.outputFiles[0].text).toContain('else factory()');
      const ctx: Record<string, any> = { self: {} };
      expect(() => new Function('self', result.outputFiles[0].text)(ctx.self)).not.toThrow();
    } finally {
      removeOptionCombinationFixture(dir);
    }
  });
});
