import { describe, test, expect, transpile } from '../helpers';

describe('@zntc/core API: type stripping', () => {
  test('인터페이스 스트리핑', () => {
    const result = transpile('interface Foo { bar: string; }\nconst x = 1;', {
      filename: 'input.ts',
    });
    expect(result.code).not.toContain('interface');
    expect(result.code).toContain('const x = 1;');
  });

  test('타입 어노테이션 제거', () => {
    const result = transpile('function add(a: number, b: number): number { return a + b; }', {
      filename: 'input.ts',
    });
    expect(result.code).toContain('function add(a,b)');
    expect(result.code).not.toContain(': number');
  });

  test('enum 변환', () => {
    const result = transpile('enum Color { Red, Green, Blue }', { filename: 'input.ts' });
    expect(result.code).toContain('Color');
  });

  test('Flow 스트리핑', () => {
    const result = transpile('// @flow\nfunction foo(x: string): number { return 1; }', {
      flow: true,
      filename: 'test.js',
    });
    expect(result.code).not.toContain(': string');
    expect(result.code).not.toContain(': number');
  });
});
