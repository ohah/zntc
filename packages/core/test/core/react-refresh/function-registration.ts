import { describe, test, expect } from '../helpers';
import { buildReactRefreshCode } from './fixture';

describe('React Refresh: function component registration', () => {
  test('function declaration은 정상적으로 $RefreshReg$에 등록', () => {
    const code = buildReactRefreshCode(`
      function MyComponent() { return null; }
      export default MyComponent;
    `);
    // function declaration 이름 "MyComponent"는 등록되어야 함
    expect(code).toContain('MyComponent');
    expect(code).toContain('$RefreshReg$');
  });

  test('arrow function은 변수명이 PascalCase면 $RefreshReg$ 등록', () => {
    const code = buildReactRefreshCode(`const MyArrow = () => null;\nexport default MyArrow;\n`);
    expect(code).toContain('$RefreshReg$');
  });

  test('export default function declaration은 $RefreshReg$ 등록', () => {
    const code = buildReactRefreshCode(`export default function MyScreen() { return null; }\n`);
    // export default function은 declaration → 등록됨
    expect(code).toContain('$RefreshReg$');
    expect(code).toContain('MyScreen');
  });
});
