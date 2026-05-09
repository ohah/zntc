import { describe, expect, test, transpile } from '../../helpers';

describe('@zntc/core edge cases: transpile large and unicode sources', () => {
  test('매우 긴 소스코드 트랜스파일', () => {
    const lines = Array.from({ length: 10000 }, (_, i) => `export const v${i}: number = ${i};`);
    const result = transpile(lines.join('\n'), { filename: 'input.ts' });
    expect(result.code).toContain('v9999 = 9999');
  });

  test('유니코드 소스코드', () => {
    const result = transpile('const 이름: string = "한글 테스트";', { filename: 'input.ts' });
    expect(result.code).toContain('한글 테스트');
  });
});
