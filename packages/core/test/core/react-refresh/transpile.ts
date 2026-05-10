import { describe, test, expect } from '../helpers';
import { transpileReactRefreshCode } from './fixture';

describe('React Refresh: transpile() single-file path', () => {
  test('reactRefresh=true 면 함수 컴포넌트에 $RefreshReg$ 등록 emit', () => {
    const code = transpileReactRefreshCode(
      `function MyComponent() { return <div /> }\nexport default MyComponent;`,
      { reactRefresh: true },
    );
    expect(code).toContain('$RefreshReg$');
    expect(code).toContain('MyComponent');
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
