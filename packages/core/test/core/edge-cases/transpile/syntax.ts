import { describe, expect, test, transpile } from '../../helpers';

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
