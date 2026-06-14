import { tokenize } from '../../../../index';
import { describe, expect, test, transpile } from '../../helpers';

describe('@zntc/core #4320: 빈 소스는 유효 입력', () => {
  test("transpile('') → 빈 출력 (에러 아님)", () => {
    expect(transpile('').code).toBe('');
  });

  test("tokenize('') → EOF 토큰만 (에러 아님)", () => {
    const toks = tokenize('');
    expect(toks.length).toBe(1);
    expect(toks[0]?.kind).toBe('<eof>');
  });

  test('null/undefined source 는 여전히 거부', () => {
    expect(() => transpile(undefined as unknown as string)).toThrow();
    expect(() => tokenize(null as unknown as string)).toThrow();
  });
});

describe('@zntc/core edge cases: transpile syntax coverage', () => {
  test('enum + namespace 병합', () => {
    const result = transpile('enum Direction { Up, Down }\nconst d: Direction = Direction.Up;', {
      filename: 'input.ts',
    });
    expect(result.code).toContain('Direction');
  });

  test('optional chaining + nullish coalescing', () => {
    const result = transpile("const x = a?.b?.c ?? 'default';");
    expect(result.code).toContain('??');
  });

  test('decorator (experimental)', () => {
    const result = transpile(
      '@sealed\nclass Greeter {\n  greeting: string;\n  constructor(message: string) { this.greeting = message; }\n}',
      { filename: 'input.ts', experimentalDecorators: true },
    );
    expect(result.code).toContain('__decorate');
  });
});
