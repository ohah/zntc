import { describe, expect, test, transpile } from '../../helpers';

describe('@zntc/core edge cases: transpile output options', () => {
  test('소스맵 + minify 동시 사용', () => {
    const result = transpile(
      'const longVariableName: number = 42;\nconsole.log(longVariableName);',
      {
        filename: 'input.ts',
        sourcemap: true,
        minify: true,
      },
    );
    expect(result.code.length).toBeLessThan(60);
    expect(result.map).toBeDefined();
    const map = JSON.parse(result.map!);
    expect(map.version).toBe(3);
  });
});
