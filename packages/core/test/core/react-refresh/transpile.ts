import { describe, test, expect } from '../helpers';
import { transpileReactRefreshCode } from './fixture';

describe('React Refresh: transpile() single-file path', () => {
  test('함수 선언 컴포넌트는 $RefreshReg$(_c, "Name") 호출 + _c 할당 emit', () => {
    const code = transpileReactRefreshCode(
      `function MyComponent() { return <div /> }\nexport default MyComponent;`,
      { reactRefresh: true },
    );
    expect(code).toContain('_c = MyComponent');
    expect(code).toContain('$RefreshReg$(_c, "MyComponent")');
  });

  test('arrow assignment 컴포넌트도 binding 이름으로 등록', () => {
    const code = transpileReactRefreshCode(
      `import * as React from 'react';\nconst MyArrow = () => <div />;\nexport default MyArrow;`,
      { reactRefresh: true },
    );
    expect(code).toContain('_c = MyArrow');
    expect(code).toContain('$RefreshReg$(_c, "MyArrow")');
  });

  test('function expression assignment 컴포넌트도 binding 이름으로 등록', () => {
    const code = transpileReactRefreshCode(
      `const MyFE = function() { return null; };\nexport default MyFE;`,
      { filename: 'MyFE.tsx', reactRefresh: true },
    );
    expect(code).toContain('_c = MyFE');
    expect(code).toContain('$RefreshReg$(_c, "MyFE")');
  });

  test.each([{ reactRefresh: undefined }, { reactRefresh: false as const }])(
    'reactRefresh=$reactRefresh 면 $RefreshReg$ emit 안 함',
    (opts) => {
      const code = transpileReactRefreshCode(
        `function MyComponent() { return <div /> }\nexport default MyComponent;`,
        opts,
      );
      expect(code).not.toContain('$RefreshReg$');
    },
  );

  test('소문자(non-component) 함수는 등록 대상 아님', () => {
    const code = transpileReactRefreshCode(
      `function helper() { return null; }\nexport { helper };`,
      {
        filename: 'helper.ts',
        reactRefresh: true,
      },
    );
    expect(code).not.toContain('$RefreshReg$');
  });
});
