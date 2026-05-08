import { describe, test, expect, transpile } from '../helpers';

describe('@zntc/core API: output options', () => {
  test('소스맵 생성', () => {
    const result = transpile('const x: number = 1;', { filename: 'input.ts', sourcemap: true });
    expect(result.code).toContain('const x = 1;');
    expect(result.map).toBeDefined();
    const map = JSON.parse(result.map!);
    expect(map.version).toBe(3);
    expect(map.mappings).toBeDefined();
  });

  test('minify', () => {
    const result = transpile('const   x: number   =   1;', {
      filename: 'input.ts',
      minifyWhitespace: true,
    });
    expect(result.code.length).toBeLessThan('const   x   =   1;'.length);
  });

  test('CJS 포맷', () => {
    const result = transpile('export const x = 1; export default "hello";', {
      filename: 'input.ts',
      format: 'cjs',
    });
    expect(result.code).toContain('exports');
  });

  test('drop console', () => {
    const result = transpile('console.log("hello"); const x = 1;', {
      dropConsole: true,
    });
    expect(result.code).not.toContain('console.log');
    expect(result.code).toContain('const x = 1;');
  });

  test('minify 단축 옵션 (whitespace + identifiers + syntax)', () => {
    const result = transpile('const   longVariableName: number   =   1;', {
      filename: 'input.ts',
      minify: true,
    });
    expect(result.code.length).toBeLessThan('const longVariableName = 1;'.length);
  });

  test('drop debugger', () => {
    const result = transpile('debugger; const x = 1;', {
      dropDebugger: true,
    });
    expect(result.code).not.toContain('debugger');
    expect(result.code).toContain('const x = 1;');
  });

  test('quotes: single', () => {
    const result = transpile('const x = "hello";', { quotes: 'single' });
    expect(result.code).toContain("'hello'");
  });

  test('ascii only', () => {
    const result = transpile('const x = "한글";');
    const asciiResult = transpile('const x = "한글";', { asciiOnly: true });
    expect(asciiResult.code).toContain('\\u');
    expect(result.code).toContain('한글');
  });
});
