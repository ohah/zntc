import { describe, test, expect, init, transpile } from '../helpers';

describe('@zntc/core API: lifecycle', () => {
  test('init 중복 호출은 무시', () => {
    expect(() => init()).not.toThrow();
  });

  test('여러 번 호출해도 메모리 누수 없이 동작', () => {
    for (let i = 0; i < 100; i++) {
      const result = transpile(`const x${i}: number = ${i};`, { filename: 'input.ts' });
      expect(result.code).toContain(`const x${i} = ${i};`);
    }
  });
});
