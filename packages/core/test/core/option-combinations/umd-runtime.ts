import {
  afterAll,
  beforeAll,
  build,
  createOptionCombinationFixture,
  describe,
  expect,
  join,
  removeOptionCombinationFixture,
  test,
  writeFileSync,
} from './helpers';

describe('옵션 조합 통합 테스트 - UMD runtime', () => {
  let dir: string;

  beforeAll(() => {
    dir = createOptionCombinationFixture();
  });

  afterAll(() => {
    removeOptionCombinationFixture(dir);
  });

  test('format: umd + globalName → 글로벌 변수로 실행 가능', async () => {
    const result = await build({
      entryPoints: [join(dir, 'lib.ts')],
      format: 'umd',
      globalName: 'MyLib',
    });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    // 구조 확인
    expect(text).toContain('typeof define === "function"');
    expect(text).toContain('root.MyLib = factory()');
    // 실제 런타임 실행: 글로벌 변수로 접근
    const ctx: Record<string, any> = { self: {} };
    new Function('self', text)(ctx.self);
    expect((ctx.self as any).MyLib).toBeDefined();
    expect((ctx.self as any).MyLib.util()).toBe(42);
  });

  test('format: umd → CJS 모드로 실행 가능', async () => {
    const result = await build({
      entryPoints: [join(dir, 'lib.ts')],
      format: 'umd',
      globalName: 'MyLib',
    });
    // CJS 시뮬레이션: module.exports에 할당
    const mod: any = { exports: {} };
    new Function('module', 'exports', result.outputFiles[0].text)(mod, mod.exports);
    expect(mod.exports.util()).toBe(42);
  });

  test('format: umd (globalName 없음) → factory 직접 실행', async () => {
    const result = await build({
      entryPoints: [join(dir, 'lib.ts')],
      format: 'umd',
    });
    expect(result.errors.length).toBe(0);
    // globalName 없으면 "else factory()" 경로
    expect(result.outputFiles[0].text).toContain('else factory()');
    // 에러 없이 실행 가능한지 확인
    const ctx: Record<string, any> = { self: {} };
    expect(() => new Function('self', result.outputFiles[0].text)(ctx.self)).not.toThrow();
  });

  test('format: umd + minify → 압축 후 런타임 실행', async () => {
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
  });

  test('format: umd + 다중 export → 모든 export 접근 가능', async () => {
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
  });

  test('format: umd + sourcemap → 소스맵 생성', async () => {
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
  });

  test('format: umd + external → 외부 모듈 제외', async () => {
    writeFileSync(join(dir, 'ext.ts'), 'import React from "react";\nexport default React;');
    const result = await build({
      entryPoints: [join(dir, 'ext.ts')],
      format: 'umd',
      globalName: 'App',
      external: ['react'],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('require');
  });
});
