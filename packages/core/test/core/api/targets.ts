import { describe, test, expect, transpile } from '../helpers';

describe('@zntc/core API: targets', () => {
  test('ES5 다운레벨링', () => {
    const result = transpile('const x = () => 1;', { target: 'es5' });
    expect(result.code).not.toContain('=>');
    expect(result.code).toContain('function');
  });

  test('ES2015 다운레벨링 (template literal)', () => {
    const result = transpile('const s = `hello ${name}`;', { target: 'es5' });
    expect(result.code).not.toContain('`');
  });

  test('target esnext (변환 없음)', () => {
    const result = transpile('const x = () => 1;', { target: 'esnext' });
    expect(result.code).toContain('=>');
  });

  test('platform node', () => {
    const result = transpile('const x: number = 1;', { filename: 'input.ts', platform: 'node' });
    expect(result.code).toContain('const x = 1;');
  });

  test('useDefineForClassFields false', () => {
    const result = transpile('class A { x = 1; }', { useDefineForClassFields: false });
    expect(result.code).toContain('this.x');
  });
});
