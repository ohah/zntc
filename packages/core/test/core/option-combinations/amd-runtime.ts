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
} from './helpers';

describe('옵션 조합 통합 테스트 - AMD runtime', () => {
  let dir: string;

  beforeAll(() => {
    dir = createOptionCombinationFixture();
  });

  afterAll(() => {
    removeOptionCombinationFixture(dir);
  });

  test('format: amd → define 콜백으로 실행 가능', async () => {
    const result = await build({
      entryPoints: [join(dir, 'lib.ts')],
      format: 'amd',
    });
    expect(result.errors.length).toBe(0);
    // AMD 시뮬레이션: define(deps, factory) 호출 캡처
    let amdResult: any = null;
    const define: any = (_deps: any, factory: () => any) => {
      amdResult = factory();
    };
    define.amd = true;
    new Function('define', result.outputFiles[0].text)(define);
    expect(amdResult).toBeDefined();
    expect(amdResult.util()).toBe(42);
  });

  test('format: amd + minify → 압축 후 런타임 실행', async () => {
    const result = await build({
      entryPoints: [join(dir, 'lib.ts')],
      format: 'amd',
      minify: true,
    });
    expect(result.errors.length).toBe(0);
    let amdResult: any = null;
    const define: any = (_: any, factory: () => any) => {
      amdResult = factory();
    };
    define.amd = true;
    new Function('define', result.outputFiles[0].text)(define);
    expect(amdResult.util()).toBe(42);
  });
});
