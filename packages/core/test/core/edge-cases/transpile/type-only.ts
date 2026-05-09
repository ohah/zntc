import { describe, expect, test, transpile } from '../../helpers';

describe('@zntc/core edge cases: transpile type-only sources', () => {
  test('빈 인터페이스만 있는 파일', () => {
    const result = transpile('interface Empty {}\n', { filename: 'input.ts' });
    expect(result.code.trim()).toBe('');
  });

  test('타입만 있는 파일', () => {
    const result = transpile('type Foo = string;\ntype Bar = number;\n', { filename: 'input.ts' });
    expect(result.code.trim()).toBe('');
  });

  test('복잡한 제네릭 타입', () => {
    const result = transpile(
      'function identity<T extends Record<string, unknown>>(x: T): T { return x; }',
      { filename: 'input.ts' },
    );
    expect(result.code).toContain('function identity(x)');
    expect(result.code).not.toContain('<T');
  });
});
