import { describe, test, expect } from '../helpers';
import { buildReactRefreshCode } from './fixture';

describe('React Refresh: ignored non-component symbols', () => {
  test('function expression 이름이 $RefreshReg$에 등록되지 않아야 함', () => {
    const code = buildReactRefreshCode(`
      const MyComp = function MyCompFactory() { return null; };
      export default MyComp;
    `);
    // function expression 이름 "MyCompFactory"가 $RefreshReg$에 등록되면 안 됨
    expect(code).not.toContain('$RefreshReg$(_c, "MyCompFactory")');
    // function declaration이 아니므로 외부에서 참조 불가
    expect(code).not.toContain('_c = MyCompFactory');
  });

  test('named function expression을 인자로 전달해도 $RefreshReg$ 미등록', () => {
    const code = buildReactRefreshCode(`
      function App() {
        const handler = someHook(function HandlerFactory() { return 1; }, []);
        return handler;
      }
      export default App;
    `);
    expect(code).not.toContain('"HandlerFactory"');
  });

  test('lowercase function name은 $RefreshReg$ 미등록 (컴포넌트 아님)', () => {
    const code = buildReactRefreshCode(`function helper() { return 1; }\nexport default helper;\n`);
    // lowercase 함수는 컴포넌트가 아니므로 등록 안 함
    expect(code).not.toContain('"helper"');
  });

  test('class component는 $RefreshReg$ 미등록 (함수만 등록)', () => {
    const code = buildReactRefreshCode(
      `class MyClassComp { render() { return null; } }\nexport default MyClassComp;\n`,
    );
    // class는 React Refresh 등록 대상이 아님 (함수 컴포넌트만 등록)
    expect(code).not.toContain('"MyClassComp"');
  });
});
