import { describe, test, expect, init, transpile, build, buildSync, close } from '../helpers';

describe('@zntc/core edge cases: init lifecycle', () => {
  test('init 전에 transpile 호출 시 에러', () => {
    close();
    expect(() => transpile('const x = 1;')).toThrow('not initialized');
    init();
  });

  test('init 전에 buildSync 호출 시 에러', () => {
    close();
    expect(() => buildSync({ entryPoints: ['/nonexistent'] })).toThrow('not initialized');
    init();
  });

  test('init 전에 build 호출 시 에러', async () => {
    close();
    await expect(build({ entryPoints: ['/nonexistent'] })).rejects.toThrow('not initialized');
    init();
  });
});
