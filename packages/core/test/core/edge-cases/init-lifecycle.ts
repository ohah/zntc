import { describe, test, expect, transpile, build, buildSync, close } from '../helpers';

// 4d33c4a8 이후 native API 는 lazy auto-init — 사용자가 init() 을 명시 호출하지 않아도
// 첫 호출 시점에 ensureNative() 가 자동 init. 이전 contract ("init 전 호출은 throw") 는
// 더 이상 유효하지 않다. 이 파일은 *close() 후에도 다음 호출에서 자동 재초기화되어
// 정상 동작* 한다는 새 contract 를 가드.
describe('@zntc/core edge cases: init lifecycle (lazy auto-init)', () => {
  test('close 후 transpile 호출 시 자동 재초기화', () => {
    close();
    const result = transpile('const x = 1;');
    expect(result.code).toContain('x');
  });

  test('close 후 buildSync 호출 시 자동 재초기화', () => {
    close();
    // entryPoints 가 nonexistent 라 build 단계는 errors 를 만들지만, init 단계는 통과해야 함.
    const result = buildSync({ entryPoints: ['/nonexistent/file.ts'] });
    expect(result).toBeDefined();
  });

  test('close 후 build 호출 시 자동 재초기화', async () => {
    close();
    const result = await build({ entryPoints: ['/nonexistent/file.ts'] });
    expect(result).toBeDefined();
  });
});
