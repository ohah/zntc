import { describe, test, expect, transpile } from '../helpers';

describe('@zntc/core API: source kind', () => {
  test('기본 standalone transpile은 JS로 파싱해 TypeScript syntax를 거부', () => {
    expect(() => transpile('const x: number = 1;')).toThrow('ParseError');
  });

  test('명시적 TypeScript filename은 TypeScript syntax를 허용', () => {
    const result = transpile('const x: number = 1;', { filename: 'input.ts' });
    expect(result.code).toContain('const x = 1;');
    expect(result.map).toBeUndefined();
  });

  test('transpile: 명시적 .ts filename은 JSX syntax를 거부', () => {
    expect(() => transpile('const x = <div />;', { filename: 'input.ts' })).toThrow('ParseError');
  });

  test('transpile: 명시적 .js/.jsx filename은 TypeScript syntax를 거부', () => {
    expect(() => transpile('const x: number = 1;', { filename: 'input.js' })).toThrow('ParseError');
    expect(() =>
      transpile('const h = (tag) => tag;\nconst x: string = <div />;', {
        filename: 'input.jsx',
        jsx: 'classic',
        jsxFactory: 'h',
      }),
    ).toThrow('ParseError');

    const jsxOnly = transpile('const h = (tag) => tag;\nconst x = <div />;', {
      filename: 'input.jsx',
      jsx: 'classic',
      jsxFactory: 'h',
    });
    expect(jsxOnly.code).not.toContain('<div');
  });

  test('빈 소스는 빈 출력 (빈 파일은 유효 입력)', () => {
    // 7095b96d: transpile/tokenize 가 빈 소스('')를 유효 입력(빈 출력)으로 처리 — esbuild 정렬.
    expect(transpile('').code).toBe('');
  });

  test('파싱 에러', () => {
    expect(() => transpile('const = ;')).toThrow();
  });
});
