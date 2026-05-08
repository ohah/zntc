import {
  afterAll,
  beforeAll,
  buildSync,
  createOptionCombinationFixture,
  describe,
  expect,
  join,
  removeOptionCombinationFixture,
  test,
} from './helpers';

describe('옵션 조합 통합 테스트 - basic formats', () => {
  let dir: string;

  beforeAll(() => {
    dir = createOptionCombinationFixture();
  });

  afterAll(() => {
    removeOptionCombinationFixture(dir);
  });

  test('format: cjs + platform: node 조합', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'lib.ts')],
      format: 'cjs',
      platform: 'node',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('use strict');
  });

  test('format: iife + globalName 조합', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'lib.ts')],
      format: 'iife',
      globalName: 'MyLib',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('MyLib');
  });

  test('format: iife + globalName → 런타임 실행 검증', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'lib.ts')],
      format: 'iife',
      globalName: 'ILib',
    });
    expect(result.errors.length).toBe(0);
    new Function('var ILib; ' + result.outputFiles[0].text + ' return ILib;').call(null);
    // IIFE는 var ILib = (function() { ... })(); 형태
    const fn = new Function(result.outputFiles[0].text + '\nreturn ILib;');
    const lib = fn();
    expect(lib.util()).toBe(42);
  });

  test('format: cjs → use strict + 함수 선언 출력', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'lib.ts')],
      format: 'cjs',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('"use strict"');
    expect(result.outputFiles[0].text).toContain('function util()');
  });
});
