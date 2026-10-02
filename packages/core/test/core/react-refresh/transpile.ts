import { describe, test, expect } from '../helpers';
import { runInNewContext } from 'node:vm';
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

  test('ES5 lowering 경로에서도 arrow assignment 컴포넌트를 등록', () => {
    const code = transpileReactRefreshCode(
      `const PermissionDialog = () => <div />;\nexport default PermissionDialog;`,
      { target: 'es5', reactRefresh: true },
    );
    expect(code).toContain('_c = PermissionDialog');
    expect(code).toContain('$RefreshReg$(_c, "PermissionDialog")');
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

  describe('reactRefreshHookSignatures opt-in', () => {
    const src = `function MyComp() {
  const [s, setS] = useState(0);
  useEffect(() => {}, []);
  return null;
}
export default MyComp;`;

    test('opt-in 시 _s() / var _s = $RefreshSig$() / _s(Comp, "sig") 모두 emit', () => {
      const code = transpileReactRefreshCode(src, {
        filename: 'MyComp.tsx',
        reactRefresh: true,
        reactRefreshHookSignatures: true,
      });
      expect(code).toContain('var _s = $RefreshSig$()');
      expect(code).toContain('_s(MyComp,');
      expect(code).toContain('useState{[s, setS](0)}');
      expect(code).toContain('$RefreshReg$(_c, "MyComp")');
      // body 시작에 _s() 호출
      expect(code).toMatch(/function MyComp\(\) \{[\s\n]*_s\(\);/);
    });

    test('reactRefresh 만 활성 (Metro default) 이면 $RefreshSig$ 미emit', () => {
      const code = transpileReactRefreshCode(src, {
        filename: 'MyComp.tsx',
        reactRefresh: true,
      });
      expect(code).not.toContain('$RefreshSig$');
      expect(code).toContain('$RefreshReg$(_c, "MyComp")');
    });

    test('hook 사용 없는 컴포넌트는 signature 자체 미생성 (registration 만)', () => {
      const code = transpileReactRefreshCode(
        `function NoHooks() { return null; }\nexport default NoHooks;`,
        { filename: 'NoHooks.tsx', reactRefresh: true, reactRefreshHookSignatures: true },
      );
      expect(code).not.toContain('$RefreshSig$');
      expect(code).toContain('$RefreshReg$(_c, "NoHooks")');
    });

    test('reactRefresh 비활성 + hook signatures 만 활성은 둘 다 미emit (registration 의존)', () => {
      const code = transpileReactRefreshCode(src, {
        filename: 'MyComp.tsx',
        reactRefreshHookSignatures: true,
      });
      expect(code).not.toContain('$RefreshSig$');
      expect(code).not.toContain('$RefreshReg$');
    });

    test('identifier minify가 helper 이름과 refresh handle 충돌을 피하고 등록 심볼을 따라간다', () => {
      const code = transpileReactRefreshCode(
        `
          const _c = 100;
          const _c2 = 200;
          const _s = 300;
          const _s2 = 400;
          const $RefreshReg$ = 'local-reg';
          const $RefreshSig$ = 'local-sig';
          function App() {
            const state = useState(1);
            return state + _c + _s;
          }
          function Card() { return _c2 + _s2; }
          function readLocalRefreshNames() { return [$RefreshReg$, $RefreshSig$]; }
          globalThis.runRefreshResults = () => [App(), Card(), readLocalRefreshNames()];
        `,
        {
          filename: 'RefreshCollision.tsx',
          target: 'es5',
          minifyIdentifiers: true,
          reactRefresh: true,
          reactRefreshHookSignatures: true,
        },
      );

      const registrations: Array<{ component: () => number; name: string }> = [];
      const signatures: Array<{ component: () => number; signature: string }> = [];
      const context: Record<string, unknown> = {
        $RefreshReg$: (component: () => number, name: string) =>
          registrations.push({ component, name }),
        $RefreshSig$:
          () =>
          (...args: unknown[]) => {
            if (args.length === 2)
              signatures.push({ component: args[0] as () => number, signature: args[1] as string });
          },
        useState: (value: number) => value,
      };

      runInNewContext(code, context);
      expect((context.runRefreshResults as () => unknown[])()).toEqual([
        401,
        600,
        ['local-reg', 'local-sig'],
      ]);
      expect(registrations.map(({ name }) => name).sort()).toEqual(['App', 'Card']);
      expect(registrations.find(({ name }) => name === 'App')?.component()).toBe(401);
      expect(registrations.find(({ name }) => name === 'Card')?.component()).toBe(600);
      expect(signatures).toHaveLength(1);
      expect(signatures[0].component()).toBe(401);
      expect(signatures[0].signature).toContain('useState');
    });

    test('React Refresh를 켜도 direct eval이 읽는 지역 이름을 유지한다', () => {
      const code = transpileReactRefreshCode(
        `
          function App() {
            const evalVisibleName = 73;
            return eval('evalVisibleName');
          }
          globalThis.runApp = () => App();
        `,
        { filename: 'RefreshEval.jsx', minifyIdentifiers: true, reactRefresh: true },
      );
      const context: Record<string, unknown> = {
        $RefreshReg$: () => {},
      };

      runInNewContext(code, context);
      expect((context.runApp as () => number)()).toBe(73);
    });

    test('Flow 입력도 지원되는 문법이면 transform 심볼 그래프를 사용한다', () => {
      const code = transpileReactRefreshCode(
        `
          const outside: number = 19;
          function App(): number {
            const local: number = 23;
            return local + outside;
          }
          globalThis.runApp = () => App();
        `,
        { filename: 'RefreshFlow.js', flow: true, minifyIdentifiers: true, reactRefresh: true },
      );
      const registrations: string[] = [];
      const context: Record<string, unknown> = {
        $RefreshReg$: (_component: unknown, name: string) => registrations.push(name),
      };

      runInNewContext(code, context);
      expect((context.runApp as () => number)()).toBe(42);
      expect(registrations).toEqual(['App']);
    });
  });
});
